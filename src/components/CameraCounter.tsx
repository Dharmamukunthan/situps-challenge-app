import { useRef, useState, useCallback } from "react";
import { usePoseDetection } from "@/hooks/usePoseDetection";
import { Button } from "@/components/ui/button";
import {
  Camera,
  CameraOff,
  RotateCcw,
  Trophy,
  Zap,
  Hand,
} from "lucide-react";

interface CameraCounterProps {
  onSessionEnd?: (reps: number) => void;
  dailyGoal?: number;
}

export function CameraCounter({
  onSessionEnd,
  dailyGoal = 100,
}: CameraCounterProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [cameraOn, setCameraOn] = useState(false);
  const [sessionActive, setSessionActive] = useState(false);

  const {
    repCount,
    currentAngle,
    error,
    resetCount,
    isInUpPhase,
    modelLoaded,
    addManualRep,
    debugInfo,
  } = usePoseDetection(videoRef, canvasRef, cameraOn);

  const goalProgress = Math.min((repCount / dailyGoal) * 100, 100);

  const startSession = useCallback(() => {
    resetCount();
    setSessionActive(true);
    setCameraOn(true);
  }, [resetCount]);

  const endSession = useCallback(() => {
    setSessionActive(false);
    setCameraOn(false);
    onSessionEnd?.(repCount);
  }, [repCount, onSessionEnd]);

  const handleAddRep = useCallback(() => {
    addManualRep();
  }, [addManualRep]);

  // 0 = motion at bottom (lying), 100 = motion at top (sitting up)
  const angleColor =
    currentAngle > 65
      ? "text-red-400"
      : currentAngle < 35
        ? "text-green-400"
        : "text-yellow-400";

  return (
    <div className="flex flex-col items-center gap-4 w-full">
      {/* Camera viewport — always visible during session */}
      {sessionActive && (
        <div className="relative w-full max-w-md clay-card-lg overflow-hidden">
          <div className="aspect-[4/3] bg-muted relative">
            <video
              ref={videoRef}
              className="absolute inset-0 w-full h-full object-cover rounded-[var(--clay-radius)]"
              playsInline
              muted
              autoPlay
            />
            <canvas
              ref={canvasRef}
              className="absolute inset-0 w-full h-full object-cover rounded-[var(--clay-radius)]"
            />

            {/* Rep overlay on camera */}
            <div className="absolute top-3 left-3">
              <div className="clay-pill bg-background/80 backdrop-blur-sm px-4 py-2">
                <div className="flex items-center gap-2">
                  <Zap className="w-5 h-5 text-[var(--primary)]" />
                  <span className="font-bold text-2xl text-foreground">
                    {repCount}
                  </span>
                  <span className="text-xs text-muted-foreground">reps</span>
                </div>
              </div>
            </div>

            {/* Angle display */}
            {modelLoaded && (
              <div className="absolute top-3 right-12">
                <div className="clay-pill bg-background/80 backdrop-blur-sm px-3 py-2">
                  <span className={`text-sm font-bold ${angleColor}`}>
                    {currentAngle}°
                  </span>
                </div>
              </div>
            )}

            {/* Close camera button */}
            <button
              onClick={() => setCameraOn(false)}
              className="absolute top-3 right-3 w-8 h-8 rounded-full bg-background/80 flex items-center justify-center"
            >
              <CameraOff className="w-4 h-4" />
            </button>

            {/* Status text */}
            <div className="absolute bottom-3 left-3 right-3">
              <div className="clay-pill bg-background/70 backdrop-blur-sm px-4 py-2 text-center">
                <p className={`text-sm font-bold ${angleColor}`}>
                  {!modelLoaded
                    ? "Loading camera..."
                    : currentAngle > 65
                      ? "SITTING — Lie back down!"
                      : currentAngle < 35
                        ? "LYING — Sit up now!"
                        : isInUpPhase
                          ? "Good! Now lie back down"
                          : "Get in position..."}
                </p>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Camera off prompt when session active */}
      {sessionActive && !cameraOn && (
        <div
          className="w-full max-w-md clay-card p-4 cursor-pointer"
          onClick={() => setCameraOn(true)}
        >
          <div className="flex items-center gap-3">
            <Camera className="w-5 h-5 text-primary" />
            <div>
              <p className="text-sm font-medium text-foreground">
                Tap to open camera
              </p>
              <p className="text-xs text-muted-foreground">
                AI will count your situps automatically
              </p>
            </div>
          </div>
        </div>
      )}

      {/* BIG COUNTER */}
      <div className="w-full max-w-md clay-card-lg p-6 text-center">
        <p className="text-xs text-muted-foreground uppercase tracking-wider mb-1">
          Reps Completed
        </p>
        <p className="text-6xl font-black text-foreground leading-none">
          {repCount}
        </p>
        <p className="text-sm text-muted-foreground mt-1">
          of {dailyGoal} daily goal
        </p>

        <div className="w-full h-3 clay-inset overflow-hidden mt-4">
          <div
            className="h-full rounded-[var(--clay-radius)] transition-all duration-300"
            style={{
              width: `${goalProgress}%`,
              background:
                goalProgress >= 100
                  ? "linear-gradient(135deg, #b5e8d5, #5ecfb5)"
                  : "linear-gradient(135deg, #f4845f, #f8c8dc)",
            }}
          />
        </div>
        {goalProgress >= 100 && (
          <p className="mt-2 text-sm font-bold text-green-500">
            🎉 Daily goal reached!
          </p>
        )}
      </div>

      {/* +1 Manual button (backup) + Controls */}
      {sessionActive && (
        <div className="w-full max-w-md space-y-3">
          {/* Manual +1 — backup if AI misses */}
          <Button
            onClick={handleAddRep}
            className="w-full h-16 text-xl font-bold rounded-2xl active:scale-95 transition-transform"
            style={{
              background: "var(--secondary)",
              color: "var(--secondary-foreground)",
            }}
          >
            <Hand className="w-5 h-5 mr-2" />
            +1 Rep (Manual)
          </Button>

          {/* Reset + End */}
          <div className="flex gap-3">
            <Button
              onClick={() => {
                resetCount();
                setSessionActive(false);
                setCameraOn(false);
              }}
              className="clay-btn flex-1 h-12"
              style={{
                background: "var(--muted)",
                color: "var(--muted-foreground)",
              }}
            >
              <RotateCcw className="w-4 h-4 mr-2" />
              Reset
            </Button>
            <Button
              onClick={endSession}
              className="clay-btn flex-1 h-12 text-base font-semibold"
            >
              End Session
            </Button>
          </div>
        </div>
      )}

      {/* Start session */}
      {!sessionActive && (
        <div className="w-full max-w-md space-y-3">
          <Button
            onClick={startSession}
            className="clay-btn w-full h-16 text-xl font-bold"
          >
            <Camera className="w-6 h-6 mr-3" />
            Start AI Counting
          </Button>
          <p className="text-center text-xs text-muted-foreground">
            Place phone to your side. AI tracks shoulder-hip-knee angle to count
            situps. Use +1 button as backup.
          </p>
        </div>
      )}

      {/* Debug info */}
      {cameraOn && debugInfo && (
        <div className="w-full max-w-md clay-card p-2">
          <p className="text-[9px] text-muted-foreground font-mono truncate">
            {debugInfo}
          </p>
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="clay-card p-3 w-full max-w-md">
          <p className="text-xs text-red-500">{error}</p>
        </div>
      )}
    </div>
  );
}
