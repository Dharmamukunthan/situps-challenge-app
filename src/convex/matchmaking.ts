import { v } from "convex/values";
import { query, mutation } from "./_generated/server";

export function generateCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let code = "";
  for (let i = 0; i < 6; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

/** User entered the search screen (or is still searching): refresh their queue
 *  entry so the 15-minute stale purge doesn't drop an active searcher.
 *  Search runs for as long as the player is willing to wait. */
export const touchQueue = mutation({
  args: {
    userId: v.string(),
    username: v.string(),
    duration: v.number(),
  },
  handler: async (ctx, args) => {
    // Remove leftover WAITING entries from previous searches.
    // NEVER delete "matched" entries — the opponent's findMatch patches our
    // entry to matched at the same moment our heartbeat may run, and deleting
    // it here would strand the searcher while their opponent enters the battle.
    const old = await ctx.db
      .query("matchmaking")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .collect();
    for (const entry of old) {
      if (entry.status === "waiting" && entry.duration !== args.duration) {
        await ctx.db.delete(entry._id);
      }
    }

    const existing = await ctx.db
      .query("matchmaking")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .first();

    if (existing && existing.status === "waiting") {
      // Heartbeat: keep the same queue position, just refresh liveness
      await ctx.db.patch(existing._id, {
        createdAt: Date.now(),
        username: args.username,
      });
      return existing._id;
    }

    const id = await ctx.db.insert("matchmaking", {
      userId: args.userId,
      username: args.username,
      duration: args.duration,
      status: "waiting",
      createdAt: Date.now(),
    });
    return id;
  },
});

/** Poll for a match. If another waiting player with the same duration exists,
 *  pair up atomically: create the battle, point BOTH entries at it.
 *  Returns { battleId, duration, opponentName, startedAt } or null. */
export const findMatch = mutation({
  args: {
    userId: v.string(),
    username: v.string(),
    duration: v.number(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();

    // Purge stale queue entries (players who left the app while waiting).
    const staleCutoff = now - 15 * 60 * 1000;
    const queue = await ctx.db
      .query("matchmaking")
      .withIndex("by_status_duration", (q) =>
        q.eq("status", "waiting").eq("duration", args.duration),
      )
      .collect();
    for (const entry of queue) {
      if (entry.createdAt < staleCutoff) {
        await ctx.db.delete(entry._id);
      }
    }

    // Ensure my entry exists & is fresh (covers direct findMatch without touchQueue)
    let mine = await ctx.db
      .query("matchmaking")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .first();
    if (mine && mine.status !== "waiting") {
      await ctx.db.delete(mine._id);
      mine = null;
    }
    if (!mine) {
      const id = await ctx.db.insert("matchmaking", {
        userId: args.userId,
        username: args.username,
        duration: args.duration,
        status: "waiting",
        createdAt: now,
      });
      mine = await ctx.db.get(id);
    }
    if (!mine) return null;

    // Look for a DIFFERENT waiting player with the same duration
    const opponent = await ctx.db
      .query("matchmaking")
      .withIndex("by_status_duration", (q) =>
        q.eq("status", "waiting").eq("duration", args.duration),
      )
      .order("asc")
      .first();

    if (
      opponent &&
      opponent.userId !== args.userId &&
      opponent.status === "waiting"
    ) {
      // Create the battle. startedAt is set HERE on the server — both players
      // derive their countdown from this exact timestamp, so the timer is
      // always identical regardless of when each player joined the queue.
      const startedAt = now + 5000; // small head start for both clients to load
      const battleId = await ctx.db.insert("battles", {
        creatorId: opponent.userId,
        opponentId: args.userId,
        duration: args.duration,
        creatorScore: 0,
        opponentScore: 0,
        status: "active",
        startedAt,
        battleCode: generateCode(),
        matchType: "random",
      });

      // Point BOTH entries at the battle (keep rows — getMyMatch reads them)
      await ctx.db.patch(opponent._id, { status: "matched", battleId });
      await ctx.db.patch(mine._id, { status: "matched", battleId });

      return { battleId };
    }

    return null; // still waiting
  },
});

/** Poll while searching. Returns the matched battle + server start time. */
export const getMyMatch = query({
  args: { userId: v.string() },
  handler: async (ctx, args) => {
    const entry = await ctx.db
      .query("matchmaking")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .first();

    if (!entry || entry.status !== "matched" || !entry.battleId) return null;

    const battle = (await ctx.db.get(entry.battleId as any)) as any;
    if (!battle || battle.status === "finished") return null;

    const battleDoc = battle as any;
    const opponentId =
      battleDoc.creatorId === args.userId
        ? battleDoc.opponentId
        : battleDoc.creatorId;
    let opponentName = "Opponent";
    if (opponentId) {
      const oppUser = (await ctx.db.get(opponentId)) as any;
      const u = oppUser?.username || oppUser?.name;
      if (u) opponentName = u;
    }

    return {
      battleId: entry.battleId,
      duration: battleDoc.duration,
      startedAt: battleDoc.startedAt ?? Date.now(),
      opponentName,
    };
  },
});

/** Leave matchmaking / a random battle entirely. */
export const cancelMatch = mutation({
  args: { userId: v.string() },
  handler: async (ctx, args) => {
    const entries = await ctx.db
      .query("matchmaking")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .collect();
    for (const entry of entries) {
      await ctx.db.delete(entry._id);
    }
  },
});

export const getMatchStatus = query({
  args: { userId: v.string() },
  handler: async (ctx, args) => {
    const entry = await ctx.db
      .query("matchmaking")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .first();
    if (!entry) return null;
    return { status: entry.status, battleId: entry.battleId };
  },
});
