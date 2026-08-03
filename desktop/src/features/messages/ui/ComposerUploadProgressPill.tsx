import { AnimatePresence, motion, useReducedMotion } from "motion/react";

import { cn } from "@/shared/lib/cn";

export function ComposerUploadProgressPill({
  isUploading,
  onCancel,
  percentage,
}: {
  isUploading: boolean;
  onCancel: () => void;
  percentage: number;
}) {
  const reducedMotion = useReducedMotion();

  return (
    <AnimatePresence initial={false}>
      {isUploading ? (
        <motion.div
          animate="visible"
          className="relative z-0 flex justify-center pb-2"
          data-testid="composer-upload-progress-motion"
          exit="hidden"
          initial="hidden"
          variants={{
            hidden: {
              opacity: reducedMotion ? 1 : 0,
              transition: reducedMotion
                ? { duration: 0 }
                : { duration: 0.18, ease: "easeOut" },
              y: reducedMotion ? 0 : 28,
            },
            visible: {
              opacity: 1,
              transition: reducedMotion
                ? { duration: 0 }
                : { duration: 0.22, ease: "easeIn" },
              y: 0,
            },
          }}
        >
          <div
            aria-label={`Uploading ${percentage}%`}
            aria-live="polite"
            className="relative h-9 w-[18.75rem] max-w-full overflow-hidden rounded-full border border-border bg-muted"
            data-testid="composer-upload-progress"
            role="status"
          >
            <motion.div
              animate={{ width: `${percentage}%` }}
              className="absolute inset-y-0 left-0 bg-primary/[0.12] dark:bg-primary/[0.15]"
              data-testid="composer-upload-progress-fill"
              initial={false}
              transition={
                reducedMotion
                  ? { duration: 0 }
                  : { duration: 0.15, ease: "easeOut" }
              }
            />
            <div className="relative flex h-full items-center gap-2 pl-3 pr-1">
              <span className="min-w-0 flex-1 truncate text-sm font-semibold text-foreground">
                Uploading
                <span className="text-muted-foreground">
                  {" · "}
                  {percentage}%
                </span>
              </span>
              <button
                className={cn(
                  "shrink-0 rounded-full bg-transparent px-2 py-1 text-sm font-semibold text-foreground",
                  "transition-colors hover:bg-foreground/10 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring",
                )}
                data-testid="composer-upload-cancel"
                onClick={onCancel}
                type="button"
              >
                Cancel
              </button>
            </div>
          </div>
        </motion.div>
      ) : null}
    </AnimatePresence>
  );
}
