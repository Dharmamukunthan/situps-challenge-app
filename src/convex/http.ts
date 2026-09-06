/*
 * Convex HTTP API endpoints.
 *
 * Only the public endpoints needed by the Flutter app are exposed here:
 *  - auth (email OTP sign-in)             -> POST /api/sign_in
 *  - account lookup for the Flutter app   -> POST /api/user_profile
 *  - leaderboard                           -> POST /api/leaderboard
 *  - battle + matchmaking functions        -> POST /api/mutation | POST /api/query
 */
import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api } from "./_generated/api";
import { auth } from "./auth";

const http = httpRouter();

auth.addHttpRoutes(http);

/**
 * POST /api/user_profile  { username: string }
 * Returns { userId, username, usernameLocked, isSignedInUser } for the Flutter app.
 * userId is the users-table document id (string) used as the identity for battles.
 */
http.route({
  path: "/user_profile",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    try {
      const body = await request.json();
      const username = String(body?.username ?? "").trim().toLowerCase();

      const result = await ctx.runQuery(api.username.getProfileByUsername, {
        username,
      });

      return new Response(JSON.stringify({ status: "success", value: result }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    } catch (e) {
      return new Response(
        JSON.stringify({ status: "error", errorMessage: String(e) }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }
  }),
});

/**
 * POST /api/leaderboard  { mode: "today" | "overall" }
 * Returns the ranking list for the Flutter leaderboard tab.
 */
http.route({
  path: "/leaderboard",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    try {
      const body = await request.json().catch(() => ({}));
      const mode = body?.mode === "overall" ? "overall" : "today";

      const result =
        mode === "overall"
          ? await ctx.runQuery(api.situpLogs.getOverallLeaderboard, {})
          : await ctx.runQuery(api.situpLogs.getLeaderboard, {});

      return new Response(JSON.stringify({ status: "success", value: result }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    } catch (e) {
      return new Response(
        JSON.stringify({ status: "error", errorMessage: String(e) }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }
  }),
});

export default http;
