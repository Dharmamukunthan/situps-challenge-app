import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSlot,
} from "@/components/ui/input-otp";

import { useAuth } from "@/hooks/use-auth";
import logo from "@/assets/logo.svg";
import { ArrowRight, Loader2, Mail, User, Check, X } from "lucide-react";
import { useMutation, useQuery } from "convex/react";
import { api } from "@/convex/_generated/api";
import { Suspense, useEffect, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";

interface AuthProps {
  redirectAfterAuth?: string;
}

function resolveRedirectAfterAuth(
  returnTo: string | null,
  fallback = "/dashboard",
) {
  if (returnTo?.startsWith("/") && !returnTo.startsWith("//")) {
    return returnTo;
  }
  return fallback;
}

function Auth({ redirectAfterAuth }: AuthProps = {}) {
  const { isLoading: authLoading, isAuthenticated, signIn } = useAuth();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const returnToParam = searchParams.get("returnTo");
  const redirect = resolveRedirectAfterAuth(
    returnToParam,
    redirectAfterAuth,
  );
  // A scanned invite (?returnTo=/dashboard?battle=CODE) must survive sign-in
  const battleCode = useMemo(() => {
    const m = returnToParam?.match(/battle=([A-Z0-9]{4,8})/i);
    return m ? m[1].toUpperCase() : null;
  }, [returnToParam]);
  const [step, setStep] = useState<"signIn" | { email: string }>("signIn");
  const [otp, setOtp] = useState("");
  const [usernameInput, setUsernameInput] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [isGuestLoading, setIsGuestLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Live username availability (only check valid 2+ char names)
  const availability = useQuery(
    api.username.checkUsername,
    usernameInput.trim().length >= 2
      ? { username: usernameInput.trim().toLowerCase() }
      : "skip",
  );

  useEffect(() => {
    if (!authLoading && isAuthenticated) {
      navigate(redirect);
    }
  }, [authLoading, isAuthenticated, navigate, redirect]);

  // A pending username from a PREVIOUS session must not leak onto this new
  // account — email sign-in is deliberate, so drop the stale claim.
  useEffect(() => {
    if (isAuthenticated) {
      localStorage.removeItem("situp-pending-username");
      localStorage.removeItem("situp-pending-ts");
    }
  }, [isAuthenticated]);

  const handleEmailSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setIsLoading(true);
    setError(null);
    try {
      const formData = new FormData(event.currentTarget);
      await signIn("email-otp", formData);
      setStep({ email: formData.get("email") as string });
      setIsLoading(false);
    } catch (error) {
      console.error("Email sign-in error:", error);
      setError(
        error instanceof Error
          ? error.message
          : "Failed to send verification code. Please try again.",
      );
      setIsLoading(false);
    }
  };

  const handleOtpSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setIsLoading(true);
    setError(null);
    try {
      const formData = new FormData(event.currentTarget);
      await signIn("email-otp", formData);
      navigate(
        battleCode
          ? `/dashboard?battle=${battleCode}`
          : redirect,
      );
    } catch (error) {
      console.error("OTP verification error:", error);
      setError("The verification code you entered is incorrect.");
      setIsLoading(false);
      setOtp("");
    }
  };

  const handleUsernameLogin = async () => {
    const name = usernameInput.trim().toLowerCase();
    if (!name) return;
    setIsGuestLoading(true);
    setError(null);
    try {
      await signIn("anonymous");
      localStorage.setItem("situp-pending-username", name);
      localStorage.setItem("situp-pending-ts", String(Date.now()));
      navigate(
        battleCode
          ? `/dashboard?battle=${battleCode}`
          : redirect,
      );
    } catch (error) {
      localStorage.removeItem("situp-pending-username");
      localStorage.removeItem("situp-pending-ts");
      setError(
        `Failed to sign in: ${
          error instanceof Error ? error.message : "Unknown error"
        }`,
      );
      setIsGuestLoading(false);
    }
  };

  const nameIsAvailable = availability?.valid === true;
  const nameTaken = availability?.valid === false;

  return (
    <div className="min-h-screen flex flex-col">
      {/* Auth Content */}
      <div className="flex-1 flex items-center justify-center p-4">
        <div className="flex items-center justify-center h-full flex-col">
          <Card className="min-w-[350px] pb-0 border shadow-md">
            {step === "signIn" ? (
              <>
                <CardHeader className="text-center">
                  <div className="flex justify-center">
                    <img
                      src={logo}
                      alt="Logo"
                      width={64}
                      height={64}
                      className="rounded-lg mb-4 mt-4 cursor-pointer"
                      onClick={() => navigate("/")}
                    />
                  </div>
                  <CardTitle className="text-xl">Get Started</CardTitle>
                  <CardDescription>
                    Enter your email to log in or sign up
                  </CardDescription>
                </CardHeader>
                <form onSubmit={handleEmailSubmit}>
                  <CardContent>
                    <div className="relative flex items-center gap-2">
                      <div className="relative flex-1">
                        <Mail className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
                        <Input
                          name="email"
                          placeholder="name@example.com"
                          type="email"
                          className="pl-9"
                          disabled={isLoading || isGuestLoading}
                          required
                        />
                      </div>
                      <Button
                        type="submit"
                        variant="outline"
                        size="icon"
                        disabled={isLoading || isGuestLoading}
                      >
                        {isLoading ? (
                          <Loader2 className="h-4 w-4 animate-spin" />
                        ) : (
                          <ArrowRight className="h-4 w-4" />
                        )}
                      </Button>
                    </div>
                    {error && (
                      <p className="mt-2 text-sm text-red-500">{error}</p>
                    )}

                    <div className="mt-4">
                      <div className="relative">
                        <div className="absolute inset-0 flex items-center">
                          <span className="w-full border-t" />
                        </div>
                        <div className="relative flex justify-center text-xs uppercase">
                          <span className="bg-background px-2 text-muted-foreground">
                            Or
                          </span>
                        </div>
                      </div>

                      <input
                        type="text"
                        value={usernameInput}
                        onChange={(e) =>
                          setUsernameInput(
                            e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, ""),
                          )
                        }
                        placeholder="Pick a username"
                        maxLength={16}
                        className="w-full h-11 text-center text-sm font-semibold rounded-lg bg-background border border-[var(--border)] px-3 mt-4 focus:outline-none focus:ring-2 focus:ring-[var(--primary)]"
                      />
                      {usernameInput.trim().length >= 2 && availability && (
                        <p
                          className={`mt-1.5 text-xs flex items-center justify-center gap-1 ${
                            nameIsAvailable
                              ? "text-emerald-500"
                              : "text-red-500"
                          }`}
                        >
                          {nameIsAvailable ? (
                            <>
                              <Check className="h-3 w-3" /> {usernameInput} is
                              available
                            </>
                          ) : (
                            <>
                              <X className="h-3 w-3" /> {availability.error}
                            </>
                          )}
                        </p>
                      )}
                      <Button
                        type="button"
                        variant="outline"
                        className="w-full mt-3 h-11"
                        onClick={handleUsernameLogin}
                        disabled={
                          isGuestLoading ||
                          isLoading ||
                          !usernameInput.trim() ||
                          usernameInput.trim().length < 2 ||
                          nameTaken
                        }
                      >
                        {isGuestLoading ? (
                          <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                        ) : (
                          <User className="mr-2 h-4 w-4" />
                        )}
                        Play with Username
                      </Button>
                      <p className="text-[11px] text-muted-foreground text-center mt-2">
                        Guest usernames can be changed once. Sign in with email
                        to rename freely.
                      </p>
                    </div>
                  </CardContent>
                </form>
              </>
            ) : (
              <>
                <CardHeader className="text-center mt-4">
                  <CardTitle>Check your email</CardTitle>
                  <CardDescription>
                    We've sent a code to {step.email}
                  </CardDescription>
                </CardHeader>
                <form onSubmit={handleOtpSubmit}>
                  <CardContent className="pb-4">
                    <input type="hidden" name="email" value={step.email} />
                    <input type="hidden" name="code" value={otp} />

                    <div className="flex justify-center">
                      <InputOTP
                        value={otp}
                        onChange={setOtp}
                        maxLength={6}
                        disabled={isLoading}
                        onKeyDown={(e) => {
                          if (
                            e.key === "Enter" &&
                            otp.length === 6 &&
                            !isLoading
                          ) {
                            const form = (e.target as HTMLElement).closest(
                              "form",
                            );
                            if (form) {
                              form.requestSubmit();
                            }
                          }
                        }}
                      >
                        <InputOTPGroup>
                          {Array.from({ length: 6 }).map((_, index) => (
                            <InputOTPSlot key={index} index={index} />
                          ))}
                        </InputOTPGroup>
                      </InputOTP>
                    </div>
                    {error && (
                      <p className="mt-2 text-sm text-red-500 text-center">
                        {error}
                      </p>
                    )}
                    <p className="text-sm text-muted-foreground text-center mt-4">
                      Didn't receive a code?{" "}
                      <Button
                        variant="link"
                        className="p-0 h-auto"
                        onClick={() => setStep("signIn")}
                      >
                        Try again
                      </Button>
                    </p>
                  </CardContent>
                  <CardFooter className="flex-col gap-2">
                    <Button
                      type="submit"
                      className="w-full"
                      disabled={isLoading || otp.length !== 6}
                    >
                      {isLoading ? (
                        <>
                          <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                          Verifying...
                        </>
                      ) : (
                        <>
                          Verify code
                          <ArrowRight className="ml-2 h-4 w-4" />
                        </>
                      )}
                    </Button>
                    <Button
                      type="button"
                      variant="ghost"
                      onClick={() => setStep("signIn")}
                      disabled={isLoading}
                      className="w-full"
                    >
                      Use different email
                    </Button>
                  </CardFooter>
                </form>
              </>
            )}

            <div className="py-4 px-6 text-xs text-center text-muted-foreground bg-muted border-t rounded-b-lg">
              Secured by{" "}
              <a
                href="https://freebuff.com"
                target="_blank"
                rel="noopener noreferrer"
                className="underline hover:text-primary transition-colors"
              >
                freebuff.com
              </a>
            </div>
          </Card>
        </div>
      </div>
    </div>
  );
}

export default function AuthPage(props: AuthProps) {
  return (
    <Suspense>
      <Auth {...props} />
    </Suspense>
  );
}
