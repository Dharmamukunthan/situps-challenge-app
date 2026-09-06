import { useState, useEffect, useCallback, useRef, useMemo } from "react";
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";
import { Button } from "@/components/ui/button";
import { usePoseDetection } from "@/hooks/usePoseDetection";
import {
  Swords,
  Clock,
  Trophy,
  Users,
  Copy,
  Check,
  RotateCcw,
  Zap,
  ExternalLink,
  Loader2,
  Globe,
  Lock,
  Search,
  Hand,
} from "lucide-react";
import { QRCodeSVG } from "qrcode.react";
import { toast } from "sonner";

type BattlePhase =
  | "lobby"
  | "searching"
  | "waiting"
  | "prestart"
  | "active"
  | "finished";
type BattleMode = "random" | "private" | null;

const DURATIONS = [
  { value: 30, label: "30s" },
  { value: 60, label: "1 min" },
  { value: 300, label: "5 min" },
];

const HEADSTART_MS = 5000; // shared countdown window before reps count

function DurationPicker({
  value,
  onChange,
  compact = false,
}: {
  value: number;
  onChange: (v: number) => void;
  compact?: boolean;
}) {
  return (
    <div className={compact ? "mb-3" : "mb-5"}>
      {!compact && (
        <label className="text-xs font-medium text-foreground mb-2 block">
          Select Duration
        </label>
      )}
      <div className="grid grid-cols-3 gap-3">
        {DURATIONS.map((d) => (
          <button
            key={d.value}
            type="button"
            onClick={() => onChange(d.value)}
            className={`
              h-14 rounded-[var(--clay-radius)] font-bold text-base
              flex items-center justify-center
              transition-all select-none
              ${
                value === d.value
                  ? "bg-[var(--primary)] text-[var(--primary-foreground)] shadow-md scale-105"
                  : "bg-[var(--muted)] text-foreground hover:bg-[var(--accent)]/30 active:scale-95"
              }
            `}
          >
            {d.label}
          </button>
        ))}
      </div>
    </div>
  );
}

interface BattleSystemProps {
  onBack: () => void;
  initialBattleCode?: string;
  userId: string;
  username: string;
}

export function BattleSystem({
  onBack,
  initialBattleCode,
  userId,
  username,
}: BattleSystemProps) {
  const [mode, setMode] = useState<BattleMode>(
    initialBattleCode ? "private" : null,
  );
  const [phase, setPhase] = useState<BattlePhase>("lobby");
  const [duration, setDuration] = useState(60);
  const [isCreating, setIsCreating] = useState(false);
  const [isJoining, setIsJoining] = useState(false);
  const [battleId, setBattleId] = useState<string | null>(null);
  const [battleCode, setBattleCode] = useState<string>("");
  const [joinCode, setJoinCode] = useState(initialBattleCode ?? "");
  const [joinError, setJoinError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [prestartLeft, setPrestartLeft] = useState(5);
  const [timeLeft, setTimeLeft] = useState(60);
  const [myScore, setMyScore] = useState(0);
  const [opponentScore, setOpponentScore] = useState(0);
  const [manualRep, setManualRep] = useState(0);
  const myScoreRef = useRef(0);
  const durationRef = useRef(duration);

  useEffect(() => {
    durationRef.current = duration;
  }, [duration]);

  // Convex
  const createBattle = useMutation(api.battles.createBattle);
  const joinBattle = useMutation(api.battles.joinBattle);
  const updateScore = useMutation(api.battles.updateScore);
  const endBattle = useMutation(api.battles.endBattle);
  const findMatch = useMutation(api.matchmaking.findMatch);
  const cancelMatch = useMutation(api.matchmaking.cancelMatch);
  const touchQueue = useMutation(api.matchmaking.touchQueue);
  const leaveQueue = useMutation(api.matchmaking.leaveBattleQueue);

  // Live subscription: fires for both players while searching
  const myMatch = useQuery(
    api.matchmaking.getMyMatch,
    phase === "searching" ? { userId } : "skip",
  );
  const battle = useQuery(
    api.battles.getBattle,
    battleId ? { battleId: battleId as any } : "skip",
  );

  const isCreator = battle ? battle.creatorId === userId : false;

  // Pick up a match found by the OTHER player's findMatch call
  useEffect(() => {
    if (phase === "searching" && myMatch?.battleId && !battleId) {
      setBattleId(myMatch.battleId);
      setDuration(myMatch.duration);
    }
  }, [myMatch, phase, battleId]);

  // Safety poll: re-runs pairing in case of any missed race, and recreates
  // our queue entry if a stale-purge removed it mid-search.
  useEffect(() => {
    if (phase !== "searching") return;
    const poll = setInterval(() => {
      findMatch({ userId, username, duration })
        .then((result) => {
          if (result && !battleId) {
            setBattleId(result.battleId);
          }
        })
        .catch(() => {});
    }, 5000);
    return () => clearInterval(poll);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, userId, username, duration, battleId]);

  // Duration authority is the SERVER battle doc — a joiner who selected a
  // different duration in the lobby must adopt the room's duration so both
  // players always see the same clock.
  useEffect(() => {
    if (battle && battleId && battle.duration !== duration) {
      setDuration(battle.duration);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [battle?.duration, battleId]);

  // Queue heartbeat while searching — keeps the entry alive indefinitely
  useEffect(() => {
    if (phase !== "searching") return;
    touchQueue({ userId, username, duration }).catch(() => {});
    const heartbeat = setInterval(() => {
      touchQueue({ userId, username, duration }).catch(() => {});
    }, 60_000);
    return () => clearInterval(heartbeat);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, userId, username, duration]);

  // Transition into prestart/active/finished from the SERVER battle document.
  // Both players read the same startedAt, so countdowns always agree.
  const phaseKeyRef = useRef<string>("");
  useEffect(() => {
    if (!battle || !battleId) return;
    const key = `${battle._id}:${battle.status}:${battle.startedAt ?? 0}`;
    if (phaseKeyRef.current === key) return;

    if (battle.status === "finished") {
      phaseKeyRef.current = key;
      setPhase("finished");
      return;
    }
    if (battle.status !== "active" || !battle.startedAt) return;

    phaseKeyRef.current = key;
    const waitMs = battle.startedAt - Date.now();
    if (waitMs > 250) {
      setPrestartLeft(Math.ceil(waitMs / 1000));
      setPhase("prestart");
    } else {
      setPhase("active");
    }
  }, [battle, battleId]);

  // Prestart countdown → active (shared HEADSTART from startedAt)
  useEffect(() => {
    if (phase !== "prestart" || !battle?.startedAt) return;
    const tick = () => {
      const left = Math.max(0, Math.ceil((battle.startedAt! - Date.now()) / 1000));
      setPrestartLeft(left);
      if (left <= 0) setPhase("active");
    };
    tick();
    const timer = setInterval(tick, 250);
    return () => clearInterval(timer);
  }, [phase, battle?.startedAt]);

  // Battle timer — derived from server startedAt, not local start time
  useEffect(() => {
    if (phase !== "active" || !battle?.startedAt) return;
    const endsAt = battle.startedAt + battle.duration * 1000;
    const tick = () => {
      const remaining = Math.max(0, Math.ceil((endsAt - Date.now()) / 1000));
      setTimeLeft(remaining);
      if (remaining <= 0) {
        // Flush the final score FIRST, then close — with the server's 10s
        // grace window the last reps can never be rejected by the buzzer.
        updateScore({
          battleId: battleId as any,
          userId,
          score: myScoreRef.current,
        })
          .catch(() => {})
          .finally(() => {
            endBattle({ battleId: battleId as any }).catch(() => {});
          });
        setPhase("finished");
      }
    };
    tick();
    const timer = setInterval(tick, 250);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, battle?.startedAt, battle?.duration]);

  // Camera — warms up during prestart, counts during active
  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const cameraEnabled = phase === "prestart" || phase === "active";
  const { repCount, resetCount, error } = usePoseDetection(
    videoRef,
    canvasRef,
    cameraEnabled,
  );

  // Reset counters when a new battle session begins (per-battle, not per-phase,
  // so the prestart → active remount doesn't wipe the warmed-up counter state).
  useEffect(() => {
    if (phase === "prestart" && battleId) {
      resetCount();
      setMyScore(0);
      setOpponentScore(0);
      myScoreRef.current = 0;
      setManualRep(0);
      lastScoreUpdateRef.current = 0;
      cleanupRef.current = 0;
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [battleId]);

  // My live score = AI reps + manual reps. Runs in "finished" too — if the
  // opponent's endBattle closes the doc a beat before our timer hits zero,
  // the last reps must still flow into the final flush below. Score is
  // monotonically non-decreasing, so "apply first" on the server makes these
  // syncs idempotent.
  useEffect(() => {
    if (phase !== "active" && phase !== "prestart" && phase !== "finished")
      return;
    const total = repCount + manualRep;
    setMyScore(total);
    myScoreRef.current = total;
  }, [repCount, manualRep, phase]);

  // Final score flush — every change while finished (idempotent on server)
  useEffect(() => {
    if (phase === "finished" && battleId) {
      updateScore({
        battleId: battleId as any,
        userId,
        score: myScoreRef.current,
      }).catch(() => {});
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, myScore, battleId]);

  // Queue cleanup exactly once per battle (reset in resetAll / new battle)
  const cleanupRef = useRef(0);
  useEffect(() => {
    if (phase === "finished" && battleId && cleanupRef.current !== 1) {
      cleanupRef.current = 1;
      leaveQueue({ userId, battleId }).catch(() => {});
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, battleId]);

  // Push score to server (throttled)
  const lastScoreUpdateRef = useRef(0);
  useEffect(() => {
    if (phase === "active" && battleId) {
      const now = Date.now();
      if (now - lastScoreUpdateRef.current > 1000) {
        lastScoreUpdateRef.current = now;
        updateScore({
          battleId: battleId as any,
          userId,
          score: myScoreRef.current,
        }).catch(() => {});
      }
    }
  }, [myScore, phase, battleId, userId, updateScore]);

  // Opponent score (live, reactive)
  useEffect(() => {
    if (!battle) return;
    const opp = isCreator ? battle.opponentScore : battle.creatorScore;
    setOpponentScore(opp);
  }, [battle, isCreator]);

  // ----------------------------------------
  // Actions
  // ----------------------------------------
  const handleFindMatch = async () => {
    if (isCreating || !userId) return;
    setIsCreating(true);
    setJoinError(null);
    try {
      setPhase("searching");
      const result = await findMatch({ userId, username, duration });
      if (result) {
        setBattleId(result.battleId);
        // phase transitions via the battle subscription
      }
      // null → keep waiting; subscription picks up the match later
    } catch {
      setPhase("lobby");
    } finally {
      setIsCreating(false);
    }
  };

  const handleCancelSearch = useCallback(async () => {
    await cancelMatch({ userId }).catch(() => {});
    setBattleId(null);
    phaseKeyRef.current = "";
    setPhase("lobby");
  }, [cancelMatch, userId]);

  const handleCreateRoom = async () => {
    if (isCreating || !userId) return;
    setIsCreating(true);
    try {
      const result = await createBattle({ creatorId: userId, duration });
      setBattleId(result.id);
      setBattleCode(result.code);
      setPhase("waiting");
    } finally {
      setIsCreating(false);
    }
  };

  const handleJoinWithCode = useCallback(
    async (code: string) => {
      const clean = code.trim().toUpperCase();
      if (!clean || isJoining || !userId) return;
      setIsJoining(true);
      setJoinError(null);
      try {
        const result = await joinBattle({ battleCode: clean, opponentId: userId });
        if ("error" in result && result.error) {
          setJoinError(result.error);
          return;
        }
        if (result.battleId) {
          setBattleId(result.battleId);
          // prestart/active transition happens via battle subscription
        }
      } catch {
        setJoinError("Could not join. Try again.");
      } finally {
        setIsJoining(false);
      }
    },
    [isJoining, userId, joinBattle],
  );

  // Auto-join from QR / shared link (once)
  const autoJoinRef = useRef(false);
  useEffect(() => {
    if (
      initialBattleCode &&
      mode === "private" &&
      phase === "lobby" &&
      userId &&
      !autoJoinRef.current
    ) {
      autoJoinRef.current = true;
      const timer = setTimeout(() => handleJoinWithCode(initialBattleCode), 400);
      return () => clearTimeout(timer);
    }
  }, [initialBattleCode, mode, phase, userId, handleJoinWithCode]);

  const copyCode = () => {
    navigator.clipboard.writeText(battleCode).then(() => {
      toast.success("Code copied");
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  const battleUrl = useMemo(
    () =>
      battleCode
        ? `${window.location.origin}/?battle=${battleCode}`
        : "",
    [battleCode],
  );

  const resetAll = () => {
    // Closing a private room on cancel so stale codes / QR scans fail cleanly
    if (battleId) {
      endBattle({ battleId: battleId as any }).catch(() => {});
      leaveQueue({ userId, battleId }).catch(() => {});
    }
    setMode(null);
    setPhase("lobby");
    setBattleId(null);
    setBattleCode("");
    setJoinError(null);
    setMyScore(0);
    setOpponentScore(0);
    setManualRep(0);
    myScoreRef.current = 0;
    setWinner(null);
    setDuration(60);
    setTimeLeft(60);
    phaseKeyRef.current = "";
    cleanupRef.current = 0;
    resetCount();
  };

  // Winner derived from the final server document
  const [winner, setWinner] = useState<"me" | "opponent" | "draw" | null>(null);
  useEffect(() => {
    if (phase !== "finished") return;
    const my = myScoreRef.current;
    const opp = opponentScore;
    if (my > opp) setWinner("me");
    else if (opp > my) setWinner("opponent");
    else setWinner("draw");
  }, [phase, opponentScore]);

  const formatTime = (s: number) => {
    const m = Math.floor(s / 60);
    const sec = s % 60;
    return `${m}:${sec.toString().padStart(2, "0")}`;
  };

  const durationLabel =
    duration >= 60 ? `${duration / 60} min` : `${duration}s`;

  // ========================================
  // MODE SELECTOR
  // ========================================
  if (!mode) {
    return (
      <div className="flex flex-col gap-4 w-full max-w-md mx-auto">
        <div className="clay-card p-5">
          <div className="flex items-center gap-3 mb-5">
            <div className="w-10 h-10 rounded-[var(--clay-radius)] bg-[var(--primary)] flex items-center justify-center">
              <Swords className="w-5 h-5 text-white" />
            </div>
            <div>
              <h2 className="text-lg font-bold text-foreground">Head-to-Head</h2>
              <p className="text-xs text-muted-foreground">
                Choose how you want to compete.
              </p>
            </div>
          </div>

          <DurationPicker value={duration} onChange={setDuration} />

          <div className="flex flex-col gap-3">
            <button
              type="button"
              onClick={() => setMode("random")}
              className="w-full p-5 rounded-[var(--clay-radius)] bg-[var(--primary)]/10 border-2 border-[var(--primary)]/30 hover:border-[var(--primary)] transition-all text-left flex items-center gap-4 active:scale-[0.98]"
            >
              <div className="w-14 h-14 rounded-full bg-[var(--primary)] flex items-center justify-center shrink-0">
                <Globe className="w-7 h-7 text-white" />
              </div>
              <div>
                <p className="text-lg font-bold text-foreground">Random Match</p>
                <p className="text-sm text-muted-foreground">
                  Compete against a random online player
                </p>
              </div>
            </button>

            <button
              type="button"
              onClick={() => setMode("private")}
              className="w-full p-5 rounded-[var(--clay-radius)] bg-[var(--accent)]/10 border-2 border-[var(--accent)]/30 hover:border-[var(--accent)] transition-all text-left flex items-center gap-4 active:scale-[0.98]"
            >
              <div className="w-14 h-14 rounded-full bg-[var(--accent)] flex items-center justify-center shrink-0">
                <Lock className="w-7 h-7 text-[var(--accent-foreground)]" />
              </div>
              <div>
                <p className="text-lg font-bold text-foreground">Private Room</p>
                <p className="text-sm text-muted-foreground">
                  Create a room and invite friends with a code
                </p>
              </div>
            </button>
          </div>
        </div>

        <Button onClick={onBack} variant="ghost" className="w-full h-10 text-sm">
          ← Back
        </Button>
      </div>
    );
  }

  // ========================================
  // RANDOM — Searching (unlimited, cancel anytime)
  // ========================================
  if (mode === "random" && phase === "searching") {
    return (
      <div className="flex flex-col gap-4 w-full max-w-md mx-auto">
        <DurationPicker value={duration} onChange={setDuration} compact />

        <div className="clay-card-lg p-8 text-center w-full">
          <div className="w-16 h-16 rounded-[var(--clay-radius)] bg-[var(--primary)]/10 flex items-center justify-center mx-auto mb-4">
            <Search className="w-8 h-8 text-[var(--primary)] animate-pulse" />
          </div>
          <h2 className="text-2xl font-bold text-foreground mb-2">
            Finding opponent
          </h2>
          <p className="text-muted-foreground mb-1">
            Searching for a {durationLabel} match...
          </p>
          <p className="text-xs text-muted-foreground mb-4">
            We'll keep searching until someone joins.
          </p>
          <div className="flex justify-center gap-1 mb-6">
            {[0, 1, 2].map((i) => (
              <div
                key={i}
                className="w-3 h-3 rounded-full bg-[var(--primary)] animate-bounce"
                style={{ animationDelay: `${i * 0.15}s` }}
              />
            ))}
          </div>
          <p className="text-xs text-muted-foreground">
            You:{" "}
            <span className="font-semibold text-foreground">{username}</span>
          </p>
        </div>

        <Button onClick={handleCancelSearch} variant="ghost" className="w-full">
          Cancel
        </Button>
      </div>
    );
  }

  // ========================================
  // PRIVATE — Lobby (create / join)
  // ========================================
  if (mode === "private" && phase === "lobby") {
    return (
      <div className="flex flex-col gap-4 w-full max-w-md mx-auto">
        <div className="clay-card p-5">
          <div className="flex items-center gap-3 mb-5">
            <div className="w-10 h-10 rounded-[var(--clay-radius)] bg-[var(--accent)]/20 flex items-center justify-center">
              <Lock className="w-5 h-5 text-[var(--accent-foreground)]" />
            </div>
            <div>
              <h2 className="text-lg font-bold text-foreground">Private Room</h2>
              <p className="text-xs text-muted-foreground">
                Create a room or join with a code.
              </p>
            </div>
          </div>

          <DurationPicker value={duration} onChange={setDuration} />

          <Button
            onClick={handleCreateRoom}
            disabled={isCreating}
            className="clay-btn w-full h-12 text-sm font-semibold mb-4"
          >
            {isCreating ? (
              <Loader2 className="w-4 h-4 mr-2 animate-spin" />
            ) : (
              <Swords className="w-4 h-4 mr-2" />
            )}
            {isCreating ? "Creating..." : "Create Room"}
          </Button>

          <div className="clay-inset p-4">
            <label className="text-xs font-medium text-foreground mb-2 block">
              Join with Code
            </label>
            <div className="flex gap-2">
              <input
                type="text"
                value={joinCode}
                onChange={(e) => setJoinCode(e.target.value)}
                placeholder="53H7Z6"
                maxLength={6}
                autoCapitalize="characters"
                autoCorrect="off"
                spellCheck={false}
                className="flex-1 h-12 text-center text-base font-mono font-bold tracking-[0.3em] uppercase rounded-[var(--clay-radius)] bg-background border border-[var(--border)] px-3 focus:outline-none focus:ring-2 focus:ring-[var(--primary)]"
              />
              <Button
                onClick={() => handleJoinWithCode(joinCode)}
                disabled={isJoining || !joinCode.trim()}
                className="clay-btn h-12 px-5 text-sm"
              >
                {isJoining ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  "Join"
                )}
              </Button>
            </div>
            {joinError && (
              <p className="mt-2 text-xs font-medium text-destructive text-center">
                {joinError}
              </p>
            )}
          </div>
        </div>

        <Button
          onClick={() => setMode(null)}
          variant="ghost"
          className="w-full h-10 text-sm"
        >
          ← Back
        </Button>
      </div>
    );
  }

  // ========================================
  // PRIVATE — Waiting for opponent
  // ========================================
  if (phase === "waiting") {
    return (
      <div className="flex flex-col gap-4 w-full max-w-md mx-auto">
        <DurationPicker value={duration} onChange={setDuration} compact />

        <div className="clay-card-lg p-8 text-center w-full">
          <div className="w-16 h-16 rounded-[var(--clay-radius)] bg-[var(--primary)]/10 flex items-center justify-center mx-auto mb-4">
            <Users className="w-8 h-8 text-[var(--primary)]" />
          </div>
          <h2 className="text-2xl font-bold text-foreground mb-2">
            Waiting for opponent
          </h2>
          <p className="text-muted-foreground mb-6">
            Share the code or scan the QR to join.
          </p>

          <div className="clay-inset p-4 mb-4">
            <p className="text-xs text-muted-foreground mb-1">Room Code</p>
            <p className="text-4xl font-mono font-bold tracking-[0.3em] text-foreground">
              {battleCode}
            </p>
          </div>

          <div className="flex gap-2 mb-6">
            <Button onClick={copyCode} className="clay-btn flex-1 h-12">
              {copied ? (
                <Check className="w-5 h-5 mr-2" />
              ) : (
                <Copy className="w-5 h-5 mr-2" />
              )}
              {copied ? "Copied!" : "Copy Code"}
            </Button>
          </div>

          {battleUrl && (
            <>
              <div className="clay-card p-3 inline-flex flex-col items-center">
                {/* White tile so the QR stays scannable in both themes —
                    CSS-variable fg colors don't rasterize in SVG */}
                <div className="bg-white p-3 rounded-2xl">
                  <QRCodeSVG
                    value={battleUrl}
                    size={160}
                    bgColor="#ffffff"
                    fgColor="#111827"
                    level="M"
                  />
                </div>
                <p className="text-[10px] text-muted-foreground mt-2 break-all max-w-[160px]">
                  {battleUrl}
                </p>
              </div>
              <p className="text-xs text-muted-foreground mt-3">
                Scan to join this room
              </p>
            </>
          )}

          <div className="flex justify-center gap-1 mt-6">
            {[0, 1, 2].map((i) => (
              <div
                key={i}
                className="w-3 h-3 rounded-full bg-[var(--primary)] animate-bounce"
                style={{ animationDelay: `${i * 0.15}s` }}
              />
            ))}
          </div>
        </div>

        <Button onClick={resetAll} variant="ghost" className="w-full">
          Cancel Room
        </Button>
      </div>
    );
  }

  // ========================================
  // PRESTART — camera warm-up + shared countdown
  // ========================================
  if (phase === "prestart") {
    return (
      <div className="flex flex-col gap-4 w-full max-w-md mx-auto">
        <div className="clay-card-lg p-4 text-center">
          <p className="text-sm font-semibold text-foreground">
            {durationLabel} battle
          </p>
          <p className="text-xs text-muted-foreground mt-1">
            Opponent connected — get in position!
          </p>
        </div>

        <div className="relative clay-card-lg overflow-hidden">
          <div className="aspect-[4/3] bg-muted relative">
            <video
              ref={videoRef}
              className="absolute inset-0 w-full h-full object-cover"
              playsInline
              muted
              autoPlay
            />
            <canvas
              ref={canvasRef}
              className="absolute inset-0 w-full h-full object-cover"
            />
            <div className="absolute inset-0 bg-background/60 backdrop-blur-[2px] flex flex-col items-center justify-center">
              <div className="clay-counter w-28 h-28 text-6xl font-black">
                {prestartLeft}
              </div>
              <p className="mt-4 text-sm font-medium text-foreground">
                Camera warming up — stand by
              </p>
            </div>
          </div>
        </div>

        {error && (
          <div className="clay-card p-3">
            <p className="text-xs text-destructive">{error}</p>
          </div>
        )}
      </div>
    );
  }

  // ========================================
  // ACTIVE
  // ========================================
  if (phase === "active") {
    return (
      <div className="flex flex-col gap-4 w-full max-w-md mx-auto">
        <div className="clay-card-lg p-4 text-center">
          <div className="flex items-center justify-center gap-2 mb-1">
            <Clock className="w-5 h-5 text-[var(--primary)]" />
            <span className="text-4xl font-black text-foreground font-mono">
              {formatTime(timeLeft)}
            </span>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="clay-card p-4 text-center ring-2 ring-[var(--primary)]/50">
            <p className="text-xs text-muted-foreground mb-1">You</p>
            <p className="text-4xl font-black text-[var(--primary)]">
              {myScore}
            </p>
          </div>
          <div className="clay-card p-4 text-center">
            <p className="text-xs text-muted-foreground mb-1">Opponent</p>
            <p className="text-4xl font-black text-foreground">
              {opponentScore}
            </p>
          </div>
        </div>

        <div className="relative clay-card-lg overflow-hidden">
          <div className="aspect-[4/3] bg-muted relative">
            <video
              ref={videoRef}
              className="absolute inset-0 w-full h-full object-cover"
              playsInline
              muted
              autoPlay
            />
            <canvas
              ref={canvasRef}
              className="absolute inset-0 w-full h-full object-cover"
            />
            <div className="absolute top-3 left-3 clay-pill bg-background/80 backdrop-blur-sm px-4 py-2">
              <div className="flex items-center gap-2">
                <Zap className="w-4 h-4 text-[var(--primary)]" />
                <span className="font-bold text-xl text-foreground">
                  {myScore}
                </span>
              </div>
            </div>
            <div className="absolute top-3 right-3 clay-pill bg-background/80 backdrop-blur-sm px-3 py-2">
              <span className="font-bold text-sm text-foreground font-mono">
                {formatTime(timeLeft)}
              </span>
            </div>
          </div>
        </div>

        {/* Manual +1 backup — same as Count tab */}
        <Button
          onClick={() => setManualRep((m) => m + 1)}
          className="w-full h-14 text-lg font-bold rounded-2xl active:scale-95 transition-transform"
          style={{
            background: "var(--secondary)",
            color: "var(--secondary-foreground)",
          }}
        >
          <Hand className="w-5 h-5 mr-2" />
          +1 Rep (Manual)
        </Button>

        {error && (
          <div className="clay-card p-3">
            <div className="text-center">
              <p className="text-sm font-medium text-foreground mb-1">
                Camera issue
              </p>
              <p className="text-xs text-muted-foreground mb-2">{error}</p>
              <Button
                onClick={() => window.open(window.location.href, "_blank")}
                className="clay-btn h-8 px-4 text-xs"
              >
                <ExternalLink className="w-3 h-3 mr-1" />
                Open in New Tab
              </Button>
            </div>
          </div>
        )}
      </div>
    );
  }

  // ========================================
  // FINISHED
  // ========================================
  return (
    <div className="flex flex-col gap-6 w-full max-w-md mx-auto items-center">
      <div className="clay-card-lg p-8 text-center w-full">
        <div className="mb-4">
          {winner === "me" && (
            <Trophy className="w-16 h-16 text-yellow-500 mx-auto" />
          )}
          {winner === "opponent" && (
            <Trophy className="w-16 h-16 text-gray-400 mx-auto" />
          )}
          {(winner === "draw" || winner === null) && (
            <Swords className="w-16 h-16 text-[var(--primary)] mx-auto" />
          )}
        </div>

        <h2 className="text-3xl font-black text-foreground mb-2">
          {winner === "me" && "Victory"}
          {winner === "opponent" && "Defeat"}
          {(winner === "draw" || winner === null) && "Draw"}
        </h2>

        <div className="grid grid-cols-2 gap-4 mt-6">
          <div className="clay-card p-4 text-center">
            <p className="text-xs text-muted-foreground">You</p>
            <p className="text-3xl font-black text-foreground">{myScore}</p>
          </div>
          <div className="clay-card p-4 text-center">
            <p className="text-xs text-muted-foreground">Opponent</p>
            <p className="text-3xl font-black text-foreground">
              {opponentScore}
            </p>
          </div>
        </div>
      </div>

      <div className="flex gap-3 w-full">
        <Button onClick={resetAll} className="clay-btn flex-1 h-12">
          <RotateCcw className="w-5 h-5 mr-2" />
          New Battle
        </Button>
        <Button
          onClick={onBack}
          className="clay-btn flex-1 h-12"
          style={{
            background: "var(--secondary)",
            color: "var(--secondary-foreground)",
          }}
        >
          Back to Menu
        </Button>
      </div>
    </div>
  );
}
