/*
 * Convex HTTP API endpoints.
 *
 * Endpoints used by the Flutter app:
 *  - auth (email OTP sign-in)             -> POST /api/sign_in  (via auth.addHttpRoutes)
 *  - account lookup                       -> POST /api/user_profile
 *  - leaderboard                           -> POST /api/leaderboard
 *  - generic game API                      -> POST /api/query | POST /api/mutation
 *    Body: { path: "file:functionName", args: {...} }  e.g. "matchmaking:findMatch"
 *    Only the game files below are callable — nothing else is exposed.
 */
import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api } from "./_generated/api";
import { auth } from "./auth";

const http = httpRouter();

auth.addHttpRoutes(http);

// Whitelisted modules the mobile app may call through the generic endpoints.
const ALLOWED_FILES = new Set(["matchmaking", "battles", "username", "situpLogs"]);

function jsonResponse(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * POST /api/sign_in  { action: "signIn", args: { provider, params } }
 * Wraps the Convex Auth signIn action for the Flutter app's email OTP flow:
 *  - Step 1: { provider: "email-otp", params: { email } }            -> sends the code
 *  - Step 2: { provider: "email-otp", params: { email, code, flow } } -> returns tokens
 */
http.route({
  path: "/api/sign_in",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    try {
      const body = await request.json();
      if (body?.action !== "signIn") {
        return jsonResponse({ status: "error", errorMessage: "Unsupported action" });
      }

      const result = await ctx.runAction(api.auth.signIn, {
        provider: body.args?.provider,
        params: body.args?.params,
      });

      return jsonResponse({ status: "success", value: result });
    } catch (e) {
      return jsonResponse({ status: "error", errorMessage: String(e) });
    }
  }),
})

/**
 * POST /api/query | POST /api/mutation  { path: "file:function", args: {} }
 * Returns { status: "success", value } or { status: "error", errorMessage }.
 */
async function handleGameApi(ctx: any, request: Request, kind: "query" | "mutation") {
  try {
    const body = await request.json();
    const path = String(body?.path ?? "");
    const args = body?.args ?? {};

    const [file, functionName] = path.split(":");
    if (!file || !functionName || !ALLOWED_FILES.has(file)) {
      return jsonResponse({ status: "error", errorMessage: "Unknown API path" });
    }

    const apiRef = (api as any)[file]?.[functionName];
    if (!apiRef) {
      return jsonResponse({ status: "error", errorMessage: "Unknown API path" });
    }

    const value =
      kind === "query"
        ? await ctx.runQuery(apiRef, args)
        : await ctx.runMutation(apiRef, args);

    return jsonResponse({ status: "success", value });
  } catch (e) {
    return jsonResponse({ status: "error", errorMessage: String(e) });
  }
}

http.route({
  path: "/api/query",
  method: "POST",
  handler: httpAction(async (ctx, request) => handleGameApi(ctx, request, "query")),
});

http.route({
  path: "/api/mutation",
  method: "POST",
  handler: httpAction(async (ctx, request) => handleGameApi(ctx, request, "mutation")),
});

/**
 * POST /api/user_profile  { username: string }
 * Returns { userId, username, usernameLocked, isSignedInUser } for the Flutter app.
 * userId is the users-table document id (string) used as the identity for battles.
 */
http.route({
  path: "/api/user_profile",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    try {
      const body = await request.json();
      const username = String(body?.username ?? "").trim().toLowerCase();

      const result = await ctx.runQuery(api.username.getProfileByUsername, {
        username,
      });

      return jsonResponse({ status: "success", value: result });
    } catch (e) {
      return jsonResponse({ status: "error", errorMessage: String(e) });
    }
  }),
});

/**
 * POST /api/leaderboard  { mode: "today" | "overall" }
 * Returns the ranking list for the Flutter leaderboard tab.
 */
http.route({
  path: "/api/leaderboard",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    try {
      const body = await request.json().catch(() => ({}));
      const mode = body?.mode === "overall" ? "overall" : "today";

      const result =
        mode === "overall"
          ? await ctx.runQuery(api.situpLogs.getOverallLeaderboard, {})
          : await ctx.runQuery(api.situpLogs.getLeaderboard, {});

      return jsonResponse({ status: "success", value: result });
    } catch (e) {
      return jsonResponse({ status: "error", errorMessage: String(e) });
    }
  }),
});

export default http;
