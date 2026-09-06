import { v } from "convex/values";
import { query, mutation } from "./_generated/server";
import { generateCode } from "./matchmaking";

export const createBattle = mutation({
  args: {
    creatorId: v.string(),
    duration: v.number(),
  },
  handler: async (ctx, args) => {
    const code = generateCode();
    const id = await ctx.db.insert("battles", {
      creatorId: args.creatorId,
      duration: args.duration,
      creatorScore: 0,
      opponentScore: 0,
      status: "waiting",
      battleCode: code,
      matchType: "private",
    });
    return { id, code };
  },
});

export const joinBattle = mutation({
  args: {
    battleCode: v.string(),
    opponentId: v.string(),
  },
  handler: async (ctx, args) => {
    // Normalize the code so lowercase / spaced input still matches (fixes "not found")
    const code = args.battleCode.trim().toUpperCase();
    const battle = await ctx.db
      .query("battles")
      .withIndex("by_code", (q) => q.eq("battleCode", code))
      .first();

    if (!battle) return { error: "Room not found. Check the code." };
    if (battle.status === "finished")
      return { error: "This battle already ended." };
    if (battle.creatorId === args.opponentId)
      return { error: "You created this room — waiting for your opponent." };
    if (battle.opponentId && battle.opponentId !== args.opponentId)
      return { error: "This room is already full." };

    const now = Date.now();
    if (battle.startedAt && now - battle.startedAt < battle.duration * 1000) {
      // Battle already running — this player joins mid-fight (e.g. rejoining
      // after a refresh). Keep the SAME startedAt so the clock stays fair.
      await ctx.db.patch(battle._id, {
        opponentId: args.opponentId,
        status: "active",
      });
      return { battleId: battle._id };
    }
    const startedAt = battle.startedAt ?? now + 5000; // shared 5s head start

    await ctx.db.patch(battle._id, {
      opponentId: args.opponentId,
      status: "active",
      startedAt,
    });
    return { battleId: battle._id };
  },
});

export const updateScore = mutation({
  args: {
    battleId: v.id("battles"),
    userId: v.string(),
    score: v.number(),
  },
  handler: async (ctx, args) => {
    const battle = await ctx.db.get(args.battleId);
    if (!battle) throw new Error("Battle not found");
    if (battle.status === "finished") return;

    const now = Date.now();
    const elapsed = battle.startedAt ? (now - battle.startedAt) / 1000 : 0;

    // Accept final syncs a few seconds past the buzzer so the losing side's
    // last update isn't rejected; then auto-close.
    if (battle.status === "active" && battle.startedAt && elapsed > battle.duration + 5) {
      await ctx.db.patch(args.battleId, {
        status: "finished",
        endedAt: now,
      });
      return;
    }

    if (args.userId === battle.creatorId) {
      if (args.score > battle.creatorScore) {
        await ctx.db.patch(args.battleId, { creatorScore: args.score });
      }
    } else if (args.userId === battle.opponentId) {
      if (args.score > battle.opponentScore) {
        await ctx.db.patch(args.battleId, { opponentScore: args.score });
      }
    }
  },
});

export const endBattle = mutation({
  args: {
    battleId: v.id("battles"),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.battleId, {
      status: "finished",
      endedAt: Date.now(),
    });
  },
});

export const getBattle = query({
  args: { battleId: v.id("battles") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.battleId);
  },
});

// Battle with display names resolved (opponent name shown live in the app)
export const getBattleDetailed = query({
  args: { battleId: v.id("battles") },
  handler: async (ctx, args) => {
    const battle = await ctx.db.get(args.battleId);
    if (!battle) return null;
    const creatorName = await displayNameFor(ctx, battle.creatorId);
    const opponentName = battle.opponentId
      ? await displayNameFor(ctx, battle.opponentId)
      : null;
    return { ...battle, creatorName, opponentName };
  },
});

// Resolve a display name for any user id (users table, then matchmaking, then raw id)
async function displayNameFor(ctx: any, userId: string): Promise<string> {
  const user = await ctx.db.get(userId as any);
  if (user) {
    const u = (user as any).username || (user as any).name;
    if (u) return u;
  }
  const mm = await ctx.db
    .query("matchmaking")
    .withIndex("by_user", (q: any) => q.eq("userId", userId))
    .first();
  if (mm && mm.username) return mm.username;
  return "Opponent";
}

export const getBattleByCode = query({
  args: { code: v.string() },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("battles")
      .withIndex("by_code", (q) => q.eq("battleCode", args.code))
      .first();
  },
});

export const getUserBattles = query({
  args: { userId: v.string() },
  handler: async (ctx, args) => {
    const created = await ctx.db
      .query("battles")
      .withIndex("by_creator", (q) => q.eq("creatorId", args.userId))
      .order("desc")
      .collect();
    const joined = await ctx.db
      .query("battles")
      .withIndex("by_opponent", (q) => q.eq("opponentId", args.userId))
      .order("desc")
      .collect();
    const all = [...created, ...joined];
    const seen = new Set<string>();
    return all.filter((b) => {
      if (seen.has(b._id)) return false;
      seen.add(b._id);
      return true;
    });
  },
});
