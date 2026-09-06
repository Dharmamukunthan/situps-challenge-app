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

// Try to find a match. If an opponent is waiting with the same duration, pair them.
// Otherwise, add this player to the waiting queue.
export const findMatch = mutation({
  args: {
    userId: v.string(),
    username: v.string(),
    duration: v.number(),
  },
  handler: async (ctx, args) => {
    // STEP 1: Clean up ALL old matchmaking entries for this user
    const oldEntries = await ctx.db
      .query("matchmaking")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .collect();
    for (const entry of oldEntries) {
      await ctx.db.delete(entry._id);
    }

    // STEP 1b: Purge stale queue entries (players who left the app while waiting)
    const staleCutoff = Date.now() - 10 * 60 * 1000;
    const stale = await ctx.db
      .query("matchmaking")
      .withIndex("by_status_duration", (q) =>
        q.eq("status", "waiting").eq("duration", args.duration)
      )
      .collect();
    for (const entry of stale) {
      if (entry.createdAt < staleCutoff) {
        await ctx.db.delete(entry._id);
      }
    }

    // STEP 2: Look for a DIFFERENT waiting player with the same duration
    const opponent = await ctx.db
      .query("matchmaking")
      .withIndex("by_status_duration", (q) =>
        q.eq("status", "waiting").eq("duration", args.duration)
      )
      .filter((q) => q.neq(q.field("userId"), args.userId))
      .order("asc")
      .first();

    if (opponent) {
      // Found a real opponent — create battle
      const code = generateCode();
      const battleId = await ctx.db.insert("battles", {
        creatorId: opponent.userId,
        opponentId: args.userId,
        duration: args.duration,
        creatorScore: 0,
        opponentScore: 0,
        status: "active",
        startedAt: Date.now(),
        battleCode: code,
        matchType: "random",
      });

      // Update OPPONENT's entry to 'matched' so their getMyMatch query returns the battleId
      await ctx.db.patch(opponent._id, {
        status: "matched",
        battleId: battleId as any,
      });

      // Mark this user as matched too
      await ctx.db.insert("matchmaking", {
        userId: args.userId,
        username: args.username,
        duration: args.duration,
        status: "matched",
        createdAt: Date.now(),
        battleId: battleId as any,
      });

      return battleId;
    }

    // No opponent found — add to waiting queue
    await ctx.db.insert("matchmaking", {
      userId: args.userId,
      username: args.username,
      duration: args.duration,
      status: "waiting",
      createdAt: Date.now(),
    });

    return null;
  },
});

// Check if we've been matched (poll this every 2s)
// Returns battleId, the SERVER-side duration and opponent name so both players
// always play the same duration regardless of when they joined the queue.
export const getMyMatch = query({
  args: { userId: v.string() },
  handler: async (ctx, args) => {
    const entry = await ctx.db
      .query("matchmaking")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .first();

    if (!entry) return null;
    if (entry.status === "matched" && entry.battleId) {
      const battle = (await ctx.db.get(entry.battleId as any)) as any;
      if (!battle) return null;
      const isCreator = battle.creatorId === args.userId;
      const opponentId = isCreator ? battle.opponentId : battle.creatorId;
      let opponentName = "Opponent";
      if (opponentId) {
        const oppUser = await ctx.db.get(opponentId as any);
        if (oppUser) {
          const u = (oppUser as any).username || (oppUser as any).name;
          if (u) opponentName = u;
        }
      }
      return {
        battleId: entry.battleId,
        duration: battle.duration,
        opponentName,
      };
    }
    return null;
  },
});

// Cancel matchmaking — remove from queue
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

// Get current queue position / status
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
