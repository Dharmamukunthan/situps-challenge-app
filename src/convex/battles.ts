import { v } from "convex/values";
import { query, mutation } from "./_generated/server";

function generateCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let code = "";
  for (let i = 0; i < 6; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

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
    if (!battle) throw new Error("Battle not found");
    if (battle.status !== "waiting") throw new Error("Battle already started");
    if (battle.creatorId === args.opponentId) throw new Error("Cannot join your own battle");

    const now = Date.now();
    await ctx.db.patch(battle._id, {
      opponentId: args.opponentId,
      status: "active",
      startedAt: now,
    });
    return battle._id;
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
    // Small grace window so the losing-side's final sync isn't rejected at the buzzer
    const elapsed = battle.startedAt ? (now - battle.startedAt) / 1000 : 0;

    if (elapsed >= battle.duration + 3) {
      await ctx.db.patch(args.battleId, {
        status: "finished",
        endedAt: now,
      });
      return;
    }

    if (args.userId === battle.creatorId) {
      await ctx.db.patch(args.battleId, { creatorScore: args.score });
    } else if (args.userId === battle.opponentId) {
      await ctx.db.patch(args.battleId, { opponentScore: args.score });
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
