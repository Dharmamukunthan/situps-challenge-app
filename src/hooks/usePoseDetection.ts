import { useEffect, useRef, useState, useCallback } from "react";

/**
 * Situp counter using pure motion detection — no AI model needed.
 *
 * How it works:
 * - Compares consecutive camera frames pixel-by-pixel
 * - Divides frame into horizontal bands (top/mid/bottom)
 * - Tracks where motion occurs in each band
 * - Situp pattern: motion shifts from bottom → top → bottom
 * - Much faster and more reliable than TensorFlow.js on mobile
 *
 * Phone placement: SIDE VIEW, back camera.
 */

const MOTION_THRESHOLD = 30; // pixel difference to count as motion
const BAND_COUNT = 8; // divide frame into 8 horizontal bands
const REP_CONFIRM_FRAMES = 8; // frames of consistent motion needed
const COOLDOWN_FRAMES = 20; // cooldown between reps (~0.7s)
const SAMPLE_STEP = 12; // sample every 12th pixel for speed

type Phase = "idle" | "motion_up" | "motion_down";

export function usePoseDetection(
  videoRef: React.RefObject<HTMLVideoElement | null>,
  canvasRef: React.RefObject<HTMLCanvasElement | null>,
  enabled: boolean
) {
  const [repCount, setRepCount] = useState(0);
  const [isInUpPhase, setIsInUpPhase] = useState(false);
  const [currentAngle, setCurrentAngle] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [modelLoaded, setModelLoaded] = useState(false);
  const [debugInfo, setDebugInfo] = useState("");

  const animRef = useRef(0);
  const streamRef = useRef<MediaStream | null>(null);
  const repCountRef = useRef(0);
  const cooldownRef = useRef(0);
  const phaseRef = useRef<Phase>("idle");
  const confirmRef = useRef(0);
  const prevFrameRef = useRef<Uint8ClampedArray | null>(null);
  const bandMotionRef = useRef<number[]>(new Array(BAND_COUNT).fill(0));

  // Start camera
  const startCamera = useCallback(async () => {
    try {
      let stream: MediaStream;
      try {
        // Front camera first (user's stated setup), fall back to any camera
        stream = await navigator.mediaDevices.getUserMedia({
          video: {
            facingMode: "user",
            width: { ideal: 640 },
            height: { ideal: 480 },
          },
        });
      } catch {
        stream = await navigator.mediaDevices.getUserMedia({
          video: {
            facingMode: "environment",
            width: { ideal: 640 },
            height: { ideal: 480 },
          },
        });
      }
      streamRef.current = stream;
      if (videoRef.current) {
        videoRef.current.srcObject = stream;
        await videoRef.current.play();
      }
      setError(null);
      setModelLoaded(true); // no model needed, just camera
    } catch (err) {
      const name = (err as Error).name;
      if (name === "NotAllowedError") {
        setError("Camera permission denied. Allow it in settings.");
      } else {
        setError("Camera error: " + (err as Error).message);
      }
    }
  }, [videoRef]);

  const stopCamera = useCallback(() => {
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    if (animRef.current) cancelAnimationFrame(animRef.current);
    prevFrameRef.current = null;
    setModelLoaded(false);
  }, []);

  // Core motion detection
  const detectMotion = useCallback(() => {
    const video = videoRef.current;
    const canvas = canvasRef.current;
    if (!video || !canvas || video.readyState < 2) return;

    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

    try {
      const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
      const data = imageData.data;
      const w = canvas.width;
      const h = canvas.height;

      if (!prevFrameRef.current) {
        prevFrameRef.current = new Uint8ClampedArray(data);
        return;
      }

      const prev = prevFrameRef.current;

      // Count motion in each band
      const bandHeight = Math.floor(h / BAND_COUNT);
      const bandMotion = new Array(BAND_COUNT).fill(0);
      let totalMotionPixels = 0;
      const bandPixelCounts = new Array(BAND_COUNT).fill(0);

      for (let y = 0; y < h; y += SAMPLE_STEP) {
        const band = Math.min(Math.floor(y / bandHeight), BAND_COUNT - 1);

        for (let x = 0; x < w; x += SAMPLE_STEP) {
          const i = (y * w + x) * 4;
          const diff =
            Math.abs(data[i] - prev[i]) +
            Math.abs(data[i + 1] - prev[i + 1]) +
            Math.abs(data[i + 2] - prev[i + 2]);

          if (diff > MOTION_THRESHOLD) {
            bandMotion[band]++;
            totalMotionPixels++;
          }
          bandPixelCounts[band]++;
        }
      }

      // Normalize motion per band (0.0 to 1.0)
      const normalizedMotion = bandMotion.map((m, i) =>
        bandPixelCounts[i] > 0 ? m / bandPixelCounts[i] : 0
      );

      // Total motion ratio
      const totalSampled = (w / SAMPLE_STEP) * (h / SAMPLE_STEP);
      const totalMotionRatio = totalMotionPixels / totalSampled;

      // Find where most motion is happening
      // Top bands = upper body (face, torso when sitting)
      // Bottom bands = lower body (legs, floor)
      const topBands = normalizedMotion.slice(0, BAND_COUNT / 2);
      const bottomBands = normalizedMotion.slice(BAND_COUNT / 2);

      const topMotion =
        topBands.reduce((a, b) => a + b, 0) / topBands.length;
      const bottomMotion =
        bottomBands.reduce((a, b) => a + b, 0) / bottomBands.length;

      // Motion center: 0 = all motion at top, 1 = all motion at bottom
      const motionCenter =
        topMotion + bottomMotion > 0
          ? bottomMotion / (topMotion + bottomMotion)
          : 0.5;

      // Display: map motion center to a 0-100 value
      // 0 = motion at top (sitting up), 100 = motion at bottom (lying)
      setCurrentAngle(Math.round((1 - motionCenter) * 100));

      // Store for smoothing
      bandMotionRef.current = normalizedMotion;

      // Save current frame
      prevFrameRef.current = new Uint8ClampedArray(data);

      // Draw motion bands on canvas
      ctx.clearRect(0, 0, w, h);
      for (let i = 0; i < BAND_COUNT; i++) {
        const intensity = Math.min(normalizedMotion[i] * 5, 1); // amplify for visibility
        const y = i * bandHeight;
        ctx.fillStyle =
          i < BAND_COUNT / 2
            ? `rgba(59, 130, 246, ${intensity * 0.5})`
            : `rgba(34, 197, 94, ${intensity * 0.5})`;
        ctx.fillRect(0, y, w, bandHeight);

        // Draw motion bar
        const barWidth = normalizedMotion[i] * w;
        ctx.fillStyle =
          i < BAND_COUNT / 2
            ? "rgba(59, 130, 246, 0.8)"
            : "rgba(34, 197, 94, 0.8)";
        ctx.fillRect(0, y, barWidth, 2);
      }

      // Draw labels
      ctx.font = "bold 14px sans-serif";
      ctx.fillStyle = "#fff";
      ctx.strokeStyle = "#000";
      ctx.lineWidth = 2;
      ctx.strokeText(`Motion: ${(totalMotionRatio * 100).toFixed(0)}%`, 10, 25);
      ctx.fillText(`Motion: ${(totalMotionRatio * 100).toFixed(0)}%`, 10, 25);
      ctx.strokeText(
        `Center: ${motionCenter < 0.4 ? "TOP" : motionCenter > 0.6 ? "BOTTOM" : "MIDDLE"}`,
        10,
        45
      );
      ctx.fillText(
        `Center: ${motionCenter < 0.4 ? "TOP" : motionCenter > 0.6 ? "BOTTOM" : "MIDDLE"}`,
        10,
        45
      );

      // Cooldown
      if (cooldownRef.current > 0) {
        cooldownRef.current--;
        setDebugInfo(
          `Cooldown ${cooldownRef.current} | Motion: ${(totalMotionRatio * 100).toFixed(0)}% | Center: ${motionCenter.toFixed(2)}`
        );
        return;
      }

      // Minimum motion required
      if (totalMotionRatio < 0.01) {
        setDebugInfo("No motion detected — move your body");
        return;
      }

      // === SITUP DETECTION ===
      // When doing a situp from side view:
      // 1. Motion appears in upper bands (sitting up) → topMotion increases
      // 2. Motion shifts to lower bands (lying back) → bottomMotion increases
      //
      // We detect: top motion dominant → bottom motion dominant = 1 rep

      const TOP_DOMINANT = motionCenter < 0.4; // motion is in upper half
      const BOTTOM_DOMINANT = motionCenter > 0.6; // motion is in lower half

      if (phaseRef.current === "idle") {
        // Start: look for motion in lower half (user lying down, slight movement)
        if (BOTTOM_DOMINANT && totalMotionRatio > 0.02) {
          confirmRef.current++;
          if (confirmRef.current >= REP_CONFIRM_FRAMES) {
            phaseRef.current = "motion_up";
            confirmRef.current = 0;
            setIsInUpPhase(true);
          }
        } else {
          confirmRef.current = Math.max(0, confirmRef.current - 1);
        }
      } else if (phaseRef.current === "motion_up") {
        // Looking for motion to shift upward (user sitting up)
        if (TOP_DOMINANT && totalMotionRatio > 0.02) {
          confirmRef.current++;
          if (confirmRef.current >= REP_CONFIRM_FRAMES) {
            phaseRef.current = "motion_down";
            confirmRef.current = 0;
          }
        } else if (BOTTOM_DOMINANT) {
          confirmRef.current = Math.max(0, confirmRef.current - 1);
        }
      } else if (phaseRef.current === "motion_down") {
        // Looking for motion to shift back down (user lying back)
        if (BOTTOM_DOMINANT && totalMotionRatio > 0.02) {
          confirmRef.current++;
          if (confirmRef.current >= REP_CONFIRM_FRAMES) {
            // REP COMPLETE!
            repCountRef.current += 1;
            setRepCount(repCountRef.current);
            cooldownRef.current = COOLDOWN_FRAMES;
            phaseRef.current = "idle";
            confirmRef.current = 0;
            setIsInUpPhase(false);
          }
        } else if (TOP_DOMINANT) {
          confirmRef.current = Math.max(0, confirmRef.current - 1);
        }
      }

      const posLabel = TOP_DOMINANT
        ? "UP"
        : BOTTOM_DOMINANT
          ? "DOWN"
          : "MIDDLE";
      setDebugInfo(
        `Phase: ${phaseRef.current} | Motion: ${(totalMotionRatio * 100).toFixed(0)}% | Pos: ${posLabel} | Conf: ${confirmRef.current}/${REP_CONFIRM_FRAMES}`
      );
    } catch {
      // Canvas tainted
    }
  }, [videoRef, canvasRef]);

  // Animation loop
  useEffect(() => {
    if (!enabled) {
      stopCamera();
      return;
    }

    let running = true;

    const loop = () => {
      if (!running) return;
      detectMotion();
      animRef.current = requestAnimationFrame(loop);
    };

    const init = async () => {
      await startCamera();
      if (running) loop();
    };

    init();

    return () => {
      running = false;
      stopCamera();
    };
  }, [enabled, startCamera, stopCamera, detectMotion]);

  const resetCount = useCallback(() => {
    repCountRef.current = 0;
    setRepCount(0);
    cooldownRef.current = 0;
    phaseRef.current = "idle";
    confirmRef.current = 0;
    prevFrameRef.current = null;
    setIsInUpPhase(false);
  }, []);

  const addManualRep = useCallback(() => {
    repCountRef.current += 1;
    setRepCount(repCountRef.current);
  }, []);

  return {
    repCount,
    currentAngle,
    error,
    resetCount,
    isInUpPhase,
    modelLoaded,
    addManualRep,
    debugInfo,
  };
}
