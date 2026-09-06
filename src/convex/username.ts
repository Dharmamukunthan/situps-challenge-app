import { v } from "convex/values";
import { query, mutation } from "./_generated/server";

export function validateName(username: string): string | null {
  const normalized = username.trim().toLowerCase();
  if (normalized.length < 2 || normalized.length > 16) {
    return "Username must be 2-16 characters";
  }
  if (!/^[a-zA-Z0-9_]+$/.test(normalized)) {
    return "Only letters, numbers, and underscores allowed";
  }
  return null;
}

// Check if a username is already taken (live availability for the UI)
export const checkUsername = query({
  args: { username: v.string() },
  handler: async (ctx, args) => {
    const normalized = args.username.trim().toLowerCase();
    const validationError = validateName(normalized);
    if (validationError) {
      return { valid: false, error: validationError };
    }
    const existing = await ctx.db
      .query("users")
      .withIndex("by_username", (q) => q.eq("username", normalized))
      .first();
    if (existing) {
      return { valid: false, error: "Username is already taken" };
    }
    return { valid: true, error: null };
  },
});

// Look up an account by username — used by the Flutter app to resolve its identity.
export const getProfileByUsername = query({
  args: { username: v.string() },
  handler: async (ctx, args) => {
    const normalized = args.username.trim().toLowerCase();
    const user = await ctx.db
      .query("users")
      .withIndex("by_username", (q) => q.eq("username", normalized))
      .first();
    if (!user) return null;
    return {
      userId: user._id,
      username: normalized,
      usernameLocked: (user as any).usernameLocked === true,
    };
  },
});

/** Assign a unique guest name like user1025, user1026, ... to an EXISTING user doc. */
export const assignGuestName = mutation({
  args: { userId: v.string() },
  handler: async (ctx, args) => {
    const userDoc = await ctx.db.get(args.userId as any);
    if (!userDoc) throw new Error("Account not found");
    if ((userDoc as any).username) return (userDoc as any).username as string;

    for (let attempt = 0; attempt < 50; attempt++) {
      const n = Math.floor(Math.random() * 9000) + 1000; // 1000-9999
      const candidate = `user${n}`;
      const existing = await ctx.db
        .query("users")
        .withIndex("by_username", (q) => q.eq("username", candidate))
        .first();
      if (!existing) {
        await ctx.db.patch(userDoc._id as any, {
          username: candidate,
          usernameLocked: false, // one-time rename still available
        });
        return candidate;
      }
    }
    throw new Error("Could not allocate a guest username");
  },
});

/** Allocate a unique guest name like user1025, user1026, ... (creates its own doc) */
export const allocateGuestName = mutation({
  args: {},
  handler: async (ctx) => {
    for (let attempt = 0; attempt < 50; attempt++) {
      const n = Math.floor(Math.random() * 9000) + 1000; // 1000-9999
      const candidate = `user${n}`;
      const existing = await ctx.db
        .query("users")
        .withIndex("by_username", (q) => q.eq("username", candidate))
        .first();
      if (!existing) {
        const userId = await ctx.db.insert("users", {
          isAnonymous: true,
          username: candidate,
          usernameLocked: false, // hasn't used the one-time rename yet
        });
        return { userId, username: candidate };
      }
    }
    // Extremely unlikely fallback: numeric sweep
    for (let n = 1000; n <= 9999; n++) {
      const candidate = `user${n}`;
      const existing = await ctx.db
        .query("users")
        .withIndex("by_username", (q) => q.eq("username", candidate))
        .first();
      if (!existing) {
        const userId = await ctx.db.insert("users", {
          isAnonymous: true,
          username: candidate,
          usernameLocked: false,
        });
        return { userId, username: candidate };
      }
    }
    throw new Error("Could not allocate a guest username");
  },
});

// Guest username login (no email needed):
//  - If the name already exists → return that account (same person logging back in).
//  - Otherwise → create a new anonymous account with that name (one-time rename enforced).
// Idempotent: re-submitting your own name always returns your existing account.
export const registerUser = mutation({
  args: { username: v.string() },
  handler: async (ctx, args) => {
    const normalized = args.username.trim().toLowerCase();

    const validationError = validateName(normalized);
    if (validationError) throw new Error(validationError);

    const existing = await ctx.db
      .query("users")
      .withIndex("by_username", (q) => q.eq("username", normalized))
      .first();

    if (existing) {
      return {
        userId: existing._id,
        username: normalized,
        usernameLocked: (existing as any).usernameLocked === true,
      };
    }

    const userId = await ctx.db.insert("users", {
      isAnonymous: true,
      username: normalized,
      usernameLocked: true,
    });

    return { userId, username: normalized, usernameLocked: true };
  },
});

// Claim or change a username.
// Guests: ONE rename only (usernameLocked becomes true after first successful claim).
// Signed-in users: can rename unlimited times.
// Idempotent: re-sending your own current username always succeeds (no rename consumed).
export const registerUsername = mutation({
  args: {
    userId: v.string(),
    username: v.string(),
    isSignedIn: v.boolean(),
  },
  handler: async (ctx, args) => {
    const normalized = args.username.trim().toLowerCase();

    const validationError = validateName(normalized);
    if (validationError) throw new Error(validationError);

    const userDoc = await ctx.db.get(args.userId as any);

    if (!userDoc) {
      throw new Error("Account not found — please restart the app");
    }

    const currentUsername = (userDoc as any).username as string | undefined;
    const isLocked = (userDoc as any).usernameLocked === true;

    // Same name as before — nothing to do, always OK
    if (currentUsername === normalized) {
      return { username: normalized, changed: false };
    }

    // Guest already used their one-time rename
    if (!args.isSignedIn && isLocked) {
      throw new Error(
        "Guest usernames can only be changed once. Sign in to rename freely."
      );
    }

    // Name must be free (someone else can't have it)
    const existing = await ctx.db
      .query("users")
      .withIndex("by_username", (q) => q.eq("username", normalized))
      .first();
    if (existing && existing._id !== args.userId) {
      throw new Error("Username is already taken");
    }

    await ctx.db.patch(userDoc._id as any, {
      username: normalized,
      usernameLocked: args.isSignedIn ? false : true,
    });

    return { username: normalized, changed: true };
  },
});

// ---- Legacy function kept so the web app keeps working ----

// Set username — sets it on the given user document.
export const setUsername = mutation({
  args: {
    userId: v.string(),
    username: v.string(),
  },
  handler: async (ctx, args) => {
    const normalized = args.username.trim().toLowerCase();

    if (normalized.length < 2 || normalized.length > 16) {
      throw new Error("Username must be 2-16 characters");
    }
    if (!/^[a-zA-Z0-9_]+$/.test(normalized)) {
      throw new Error("Only letters, numbers, and underscores allowed");
    }

    const existing = await ctx.db
      .query("users")
      .withIndex("by_username", (q) => q.eq("username", normalized))
      .first();
    if (existing && existing._id !== args.userId) {
      throw new Error("Username is already taken");
    }

    const userDoc = await ctx.db.get(args.userId as any);
    if (!userDoc) {
      throw new Error("Could not find user account to save username");
    }

    await ctx.db.patch(userDoc._id as any, { username: normalized });
    return normalized;
  },
});

// Get username by userId
export const getUsername = query({
  args: { userId: v.string() },
  handler: async (ctx, args) => {
    const user = await ctx.db.get(args.userId as any);
    if (user && "username" in user) {
      return (user as any).username || null;
    }
    return null;
  },
});
