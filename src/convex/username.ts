import { v } from "convex/values";
import { query, mutation } from "./_generated/server";

function validateName(username: string): string | null {
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
      // Only guests are created through this path — if a signed-in user's name
      // is entered here it still resolves to their account, which is fine for
      // resuming a session on a new device.
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

// ---- Legacy functions kept so the web app keeps working ----

// Set username — tries auth context first, falls back to userId lookup
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

    // Check if username is taken by someone else
    const existing = await ctx.db
      .query("users")
      .withIndex("by_username", (q) => q.eq("username", normalized))
      .first();
    if (existing && existing._id !== args.userId) {
      throw new Error("Username is already taken");
    }

    // Try to find the user document by querying the users table
    const allUsers = await ctx.db.query("users").collect();
    const userDoc = allUsers.find((u) => u._id === args.userId);

    if (userDoc) {
      await ctx.db.patch(userDoc._id, { username: normalized });
      return normalized;
    }

    // Last resort: find any anonymous user without a username and set it
    const anonUser = allUsers.find((u) => u.isAnonymous && !u.username);
    if (anonUser) {
      await ctx.db.patch(anonUser._id, { username: normalized });
      return normalized;
    }

    throw new Error("Could not find user account to save username");
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
