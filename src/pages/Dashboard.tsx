import { useState, useCallback, useEffect } from "react";
import { useQuery, useMutation } from "convex/react";
import { api } from "@/convex/_generated/api";
import { useAuth } from "@/hooks/use-auth";
import { useSearchParams, useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Camera,
  Swords,
  Trophy,
  Sun,
  Moon,
  Shield,
  Flame,
  TrendingUp,
  Target,
  Pencil,
  Check,
  X,
  LogIn,
} from "lucide-react";
import { motion } from "framer-motion";
import { toast } from "sonner";
import { useTheme } from "@/components/ThemeProvider";
import { CameraCounter } from "@/components/CameraCounter";
import { BattleSystem } from "@/components/BattleSystem";

type Tab = "counter" | "battles" | "leaderboard";

export default function Dashboard() {
  const { user, isLoading, isAuthenticated, signOut } = useAuth();
  const { theme, toggleTheme } = useTheme();
  const [searchParams, setSearchParams] = useSearchParams();
  const navigate = useNavigate();
  const [tab, setTab] = useState<Tab>(() => {
    return searchParams.get("battle") ? ("battles" as Tab) : "counter";
  });
  const setUsernameMutation = useMutation(api.username.setUsername);
  const registerUsernameMutation = useMutation(api.username.registerUsername);
  const assignGuestNameMutation = useMutation(api.username.assignGuestName);
  const logSession = useMutation(api.situpLogs.logSession);

  const [renameOpen, setRenameOpen] = useState(false);
  const [newName, setNewName] = useState("");
  const [isRenaming, setIsRenaming] = useState(false);

  const userId = user?._id ?? "";
  const dailyCount = useQuery(
    api.situpLogs.getTodayCount,
    userId ? { userId } : "skip",
  ) ?? 0;
  const history = useQuery(api.situpLogs.getHistory, userId ? { userId } : "skip");

  const dailyGoal = 100;
  const goalProgress = Math.min(100, Math.round((dailyCount / dailyGoal) * 100));

  // Live availability for the rename dialog
  const renameAvailability = useQuery(
    api.username.checkUsername,
    newName.trim().length >= 2
      ? { username: newName.trim().toLowerCase() }
      : "skip",
  );
  const renameAvailable =
    renameAvailability?.valid === true ||
    (renameAvailability?.valid === false &&
      renameAvailability.error !== "Username is already taken" &&
      newName.trim().toLowerCase() === user?.username);

  const streak = (() => {
    if (!history || history.length === 0) return 0;
    const sorted = [...history].sort((a, b) => b.date.localeCompare(a.date));
    let expected = sorted[0].date;
    let count = 0;
    for (const log of sorted) {
      if (log.date === expected) {
        count++;
        const d = new Date(expected);
        d.setDate(d.getDate() - 1);
        expected = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
      } else if (log.date > expected) {
        continue;
      } else {
        break;
      }
    }
    return count;
  })();

  const handleSessionEnd = useCallback(
    async (reps: number) => {
      if (userId && reps > 0) {
        await logSession({ userId, sessionReps: reps }).catch(() => {});
        toast.success(`Logged ${reps} reps 🎉`);
      }
    },
    [userId, logSession],
  );

  // Save a pending username claimed on the auth page (retry until Convex confirms)
  useEffect(() => {
    if (user && !user.username) {
      const pending = localStorage.getItem("situp-pending-username");
      if (pending) {
        setUsernameMutation({ userId: user._id, username: pending })
          .then(() => {
            localStorage.removeItem("situp-pending-username");
          })
          .catch(() => {
            // Retries on next render until it succeeds
          });
      }
    }
  }, [user, setUsernameMutation]);

  // Auto-assign a unique guest name (user####) to anyone without one
  useEffect(() => {
    if (user && !user.username && !localStorage.getItem("situp-pending-username")) {
      assignGuestNameMutation({ userId: user._id })
        .then((name) => {
          localStorage.setItem("situp-pending-username", name);
        })
        .catch(() => {});
    }
  }, [user, assignGuestNameMutation]);

  // Display name: DB username → pending → name → Guest
  const displayName =
    user?.username ||
    localStorage.getItem("situp-pending-username") ||
    user?.name ||
    "Guest";

  const isGuest = user?.isAnonymous === true;
  const username = user?.username || localStorage.getItem("situp-pending-username") || "";

  const handleTabChange = (newTab: Tab) => {
    if (newTab === "battles" && !userId) {
      navigate("/auth?returnTo=/dashboard");
      return;
    }
    setTab(newTab);
  };

  const openRename = () => {
    setNewName(user?.username ?? "");
    setRenameOpen(true);
  };

  const handleRename = async () => {
    const name = newName.trim().toLowerCase();
    if (!name || name === user?.username) {
      setRenameOpen(false);
      return;
    }
    setIsRenaming(true);
    try {
      await registerUsernameMutation({
        userId,
        username: name,
        isSignedIn: !isGuest,
      });
      // Keep localStorage in sync so the name shows instantly
      localStorage.setItem("situp-pending-username", name);
      if (user && !user.username) {
        await setUsernameMutation({ userId: user._id, username: name }).catch(
          () => {},
        );
      }
      toast.success(`Username set to ${name}`);
      setRenameOpen(false);
    } catch (e) {
      toast.error(
        e instanceof Error ? e.message : "Could not rename — try another name",
      );
    } finally {
      setIsRenaming(false);
    }
  };

  const tabs: { id: Tab; icon: typeof Camera; label: string }[] = [
    { id: "counter", icon: Camera, label: "Count" },
    { id: "battles", icon: Swords, label: "Head-to-Head" },
    { id: "leaderboard", icon: Trophy, label: "Leaderboard" },
  ];

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-pulse text-muted-foreground">Loading...</div>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex flex-col">
      {/* Header */}
      <header className="clay-card rounded-t-none border-b border-border px-4 py-3 flex items-center justify-between">
        <div className="flex items-center gap-3 min-w-0">
          <div className="w-10 h-10 rounded-full bg-primary/10 flex items-center justify-center shrink-0">
            <Shield className="w-5 h-5 text-primary" />
          </div>
          <div className="min-w-0">
            <h1 className="font-semibold text-sm">Situp Challenge</h1>
            <button
              type="button"
              onClick={openRename}
              className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors"
              title="Change username"
            >
              <span className="truncate max-w-[140px]">{displayName}</span>
              <Pencil className="w-3 h-3 shrink-0" />
            </button>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Button
            variant="ghost"
            size="icon"
            className="clay-button w-9 h-9"
            onClick={toggleTheme}
          >
            {theme === "dark" ? (
              <Sun className="w-4 h-4" />
            ) : (
              <Moon className="w-4 h-4" />
            )}
          </Button>
          {isAuthenticated ? (
            <Button
              variant="ghost"
              size="sm"
              className="clay-button text-xs"
              onClick={() => signOut()}
            >
              Sign Out
            </Button>
          ) : (
            <Button
              size="sm"
              className="clay-btn text-xs"
              onClick={() => navigate("/auth?returnTo=/dashboard")}
            >
              <LogIn className="w-3.5 h-3.5 mr-1" />
              Sign In
            </Button>
          )}
        </div>
      </header>

      {/* Guest rename hint */}
      {isGuest && username && !renameOpen && (
        <div className="px-4 pt-3">
          <div className="clay-card px-3 py-2 flex items-center justify-between gap-2">
            <p className="text-[11px] text-muted-foreground">
              Guest name <span className="font-semibold">{username}</span> — you
              can change it once.
            </p>
            <Button
              variant="ghost"
              size="sm"
              className="h-6 px-2 text-[11px]"
              onClick={openRename}
            >
              Rename
            </Button>
          </div>
        </div>
      )}

      {/* Content */}
      <main className="flex-1 overflow-y-auto pb-20">
        {tab === "counter" && (
          <div>
            {/* Stats Row */}
            <div className="grid grid-cols-3 gap-3 p-4">
              <motion.div
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.1 }}
                className="clay-card p-3 flex flex-col items-center gap-1"
              >
                <Flame className="w-5 h-5 text-orange-400" />
                <span className="text-xl font-bold">{dailyCount}</span>
                <span className="text-[11px] text-muted-foreground">Today</span>
              </motion.div>
              <motion.div
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.2 }}
                className="clay-card p-3 flex flex-col items-center gap-1"
              >
                <TrendingUp className="w-5 h-5 text-emerald-400" />
                <span className="text-xl font-bold">{streak}</span>
                <span className="text-[11px] text-muted-foreground">
                  Streak
                </span>
              </motion.div>
              <motion.div
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.3 }}
                className="clay-card p-3 flex flex-col items-center gap-1"
              >
                <Target className="w-5 h-5 text-primary" />
                <span className="text-xl font-bold">{goalProgress}%</span>
                <span className="text-[11px] text-muted-foreground">Goal</span>
              </motion.div>
            </div>

            {/* Hero */}
            <div className="px-4 pb-4">
              <div className="clay-pill bg-primary/10 text-primary text-xs flex items-center gap-1.5 w-fit mx-auto px-3 py-1">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
                Camera-Powered Rep Tracking
              </div>
            </div>

            <div className="text-center px-6 pb-5">
              <h2 className="text-3xl font-bold leading-tight">
                Count situps
                <br />
                <span className="text-primary">with precision.</span>
              </h2>
              <p className="text-sm text-muted-foreground mt-3 max-w-xs mx-auto leading-relaxed">
                Point your front camera, start a session, and let pose detection
                count every rep. Compete on the leaderboard or challenge someone
                to a head-to-head battle.
              </p>
            </div>

            {/* Camera Counter */}
            <div className="px-4">
              <CameraCounter onSessionEnd={handleSessionEnd} />
            </div>
          </div>
        )}

        {tab === "battles" && userId && (
          <div className="p-4">
            <BattleSystem
              onBack={() => {
                setTab("counter");
                setSearchParams({});
              }}
              initialBattleCode={searchParams.get("battle") ?? undefined}
              userId={userId}
              username={username || displayName}
            />
          </div>
        )}

        {tab === "leaderboard" && <LeaderboardSection />}
      </main>

      {/* Bottom Nav */}
      <nav className="fixed bottom-0 left-0 right-0 clay-card rounded-b-none border-t border-border z-50">
        <div className="grid grid-cols-3">
          {tabs.map(({ id, icon: Icon, label }) => (
            <button
              key={id}
              onClick={() => handleTabChange(id)}
              className={`flex flex-col items-center gap-1 py-3 transition-colors ${
                tab === id ? "text-primary" : "text-muted-foreground"
              }`}
            >
              <Icon className="w-5 h-5" />
              <span className="text-[10px] font-medium">{label}</span>
            </button>
          ))}
        </div>
      </nav>

      {/* Rename dialog */}
      <Dialog open={renameOpen} onOpenChange={setRenameOpen}>
        <DialogContent className="clay-card-lg max-w-[calc(100vw-2rem)] sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>Change username</DialogTitle>
            <DialogDescription>
              {isGuest
                ? "Guests can rename once. Sign in with email to rename anytime."
                : "Pick any available name — you can change it again later."}
            </DialogDescription>
          </DialogHeader>
          <div className="relative">
            <Input
              value={newName}
              onChange={(e) =>
                setNewName(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, ""))
              }
              placeholder="situpmaster"
              maxLength={16}
              className="h-11 text-center font-semibold"
              disabled={isRenaming}
            />
            {newName.trim().length >= 2 && renameAvailability && (
              <p
                className={`mt-1.5 text-xs flex items-center justify-center gap-1 ${
                  renameAvailable ? "text-emerald-500" : "text-red-500"
                }`}
              >
                {renameAvailable ? (
                  <>
                    <Check className="h-3 w-3" /> {newName} is available
                  </>
                ) : (
                  <>
                    <X className="h-3 w-3" /> {renameAvailability.error}
                  </>
                )}
              </p>
            )}
          </div>
          <DialogFooter>
            <Button
              variant="ghost"
              onClick={() => setRenameOpen(false)}
              disabled={isRenaming}
            >
              Cancel
            </Button>
            <Button
              onClick={handleRename}
              disabled={
                isRenaming ||
                newName.trim().length < 2 ||
                (renameAvailability?.valid === false &&
                  newName.trim().toLowerCase() !== user?.username)
              }
            >
              {isRenaming ? "Saving..." : "Save"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function LeaderboardSection() {
  const [view, setView] = useState<"today" | "alltime">("today");
  const todayRankings = useQuery(api.situpLogs.getLeaderboard);
  const overallRankings = useQuery(api.situpLogs.getOverallLeaderboard);
  const rankings = view === "today" ? todayRankings : overallRankings;

  return (
    <div className="p-4">
      <div className="flex gap-2 mb-4">
        <button
          onClick={() => setView("today")}
          className={`clay-pill px-4 py-2 text-xs font-medium transition-colors ${
            view === "today"
              ? "bg-primary text-primary-foreground"
              : "bg-muted text-muted-foreground"
          }`}
        >
          Today
        </button>
        <button
          onClick={() => setView("alltime")}
          className={`clay-pill px-4 py-2 text-xs font-medium transition-colors ${
            view === "alltime"
              ? "bg-primary text-primary-foreground"
              : "bg-muted text-muted-foreground"
          }`}
        >
          All Time
        </button>
      </div>

      {!rankings ? (
        <div className="clay-card p-8 text-center">
          <Trophy className="w-8 h-8 text-muted-foreground mx-auto mb-2" />
          <p className="text-sm text-muted-foreground">Loading rankings...</p>
        </div>
      ) : rankings.length === 0 ? (
        <div className="clay-card p-8 text-center">
          <Trophy className="w-8 h-8 text-muted-foreground mx-auto mb-2" />
          <p className="text-sm text-muted-foreground">
            {view === "today"
              ? "No sessions logged today. Be the first!"
              : "No sessions logged yet. Be the first!"}
          </p>
        </div>
      ) : (
        <div className="space-y-2">
          {rankings.map((entry, i) => (
            <motion.div
              key={entry.userId}
              initial={{ opacity: 0, x: -10 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ delay: i * 0.05 }}
              className="clay-card px-4 py-3 flex items-center gap-3"
            >
              <div
                className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold ${
                  i === 0
                    ? "bg-yellow-500/20 text-yellow-400"
                    : i === 1
                      ? "bg-gray-300/20 text-gray-300"
                      : i === 2
                        ? "bg-orange-500/20 text-orange-400"
                        : "bg-muted text-muted-foreground"
                }`}
              >
                {i + 1}
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium truncate">{entry.userName}</p>
                {"days" in entry && view === "alltime" && (
                  <p className="text-[10px] text-muted-foreground">
                    {(entry as any).days} active days
                  </p>
                )}
              </div>
              <span className="text-sm font-bold text-primary">
                {entry.total}
              </span>
            </motion.div>
          ))}
        </div>
      )}
    </div>
  );
}
