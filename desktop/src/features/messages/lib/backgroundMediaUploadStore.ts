import * as React from "react";

import { type BlobDescriptor, uploadMediaBytes } from "@/shared/api/tauri";

export type QueuedMediaAttachment = {
  file: File;
  id: number;
  previewUrl?: string;
};

type BackgroundUploadTask = {
  canceled: boolean;
  fileProgress: number[];
  id: number;
};

type BackgroundUploadSnapshot = {
  isUploading: boolean;
  percentage: number;
};

type EnqueueBackgroundUploadOptions = {
  attachments: QueuedMediaAttachment[];
  onComplete: (descriptors: BlobDescriptor[]) => Promise<void>;
  onError: (error: unknown) => void;
};

const tasks = new Map<number, BackgroundUploadTask>();
const listeners = new Set<() => void>();
let nextTaskId = 0;
let snapshot: BackgroundUploadSnapshot = {
  isUploading: false,
  percentage: 0,
};
let stopProgressListener: (() => void) | null = null;
let progressListenerPromise: Promise<void> | null = null;

function progressId(taskId: number, fileIndex: number): string {
  return `background-media-upload-${taskId}-${fileIndex}`;
}

function rebuildSnapshot(): void {
  const allProgress = [...tasks.values()].flatMap((task) => task.fileProgress);
  snapshot = {
    isUploading: allProgress.length > 0,
    percentage:
      allProgress.length === 0
        ? 0
        : Math.round(
            allProgress.reduce((total, progress) => total + progress, 0) /
              allProgress.length,
          ),
  };
  for (const listener of listeners) listener();
}

async function ensureProgressListener(): Promise<void> {
  if (stopProgressListener || progressListenerPromise) return;
  progressListenerPromise = (async () => {
    try {
      const { listen } = await import("@tauri-apps/api/event");
      const dispose = await listen<{
        id: string;
        sent: number;
        total: number;
      }>("media-upload-progress", (event) => {
        const match = /^background-media-upload-(\d+)-(\d+)$/.exec(
          event.payload.id,
        );
        if (!match || event.payload.total <= 0) return;

        const task = tasks.get(Number(match[1]));
        const fileIndex = Number(match[2]);
        if (!task || fileIndex >= task.fileProgress.length) return;

        task.fileProgress[fileIndex] = Math.min(
          100,
          Math.max(
            0,
            Math.round((event.payload.sent / event.payload.total) * 100),
          ),
        );
        rebuildSnapshot();
      });
      if (tasks.size === 0) dispose();
      else stopProgressListener = dispose;
    } catch {
      // Browser and E2E runtimes do not emit native byte-level progress.
    } finally {
      progressListenerPromise = null;
    }
  })();
  await progressListenerPromise;
}

function finishTask(taskId: number): void {
  tasks.delete(taskId);
  rebuildSnapshot();
  if (tasks.size === 0 && stopProgressListener) {
    stopProgressListener();
    stopProgressListener = null;
  }
}

export function enqueueBackgroundMediaUpload({
  attachments,
  onComplete,
  onError,
}: EnqueueBackgroundUploadOptions): void {
  if (attachments.length === 0) {
    void onComplete([]).catch(onError);
    return;
  }

  const taskId = nextTaskId;
  nextTaskId += 1;
  const task: BackgroundUploadTask = {
    canceled: false,
    fileProgress: attachments.map(() => 0),
    id: taskId,
  };
  tasks.set(taskId, task);
  rebuildSnapshot();
  void ensureProgressListener();

  void (async () => {
    try {
      const descriptors: BlobDescriptor[] = [];
      for (let index = 0; index < attachments.length; index += 1) {
        if (task.canceled) return;
        const attachment = attachments[index];
        const buffer = await attachment.file.arrayBuffer();
        if (task.canceled) return;
        const descriptor = await uploadMediaBytes(
          [...new Uint8Array(buffer)],
          attachment.file.name,
          progressId(taskId, index),
        );
        if (task.canceled) return;
        task.fileProgress[index] = 100;
        rebuildSnapshot();
        descriptors.push(descriptor);
      }

      if (!task.canceled) await onComplete(descriptors);
    } catch (error) {
      if (!task.canceled) onError(error);
    } finally {
      finishTask(taskId);
    }
  })();
}

export function cancelBackgroundMediaUploads(): void {
  for (const task of tasks.values()) task.canceled = true;
  tasks.clear();
  rebuildSnapshot();
  stopProgressListener?.();
  stopProgressListener = null;
}

export const resetBackgroundMediaUploads = cancelBackgroundMediaUploads;

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function getSnapshot(): BackgroundUploadSnapshot {
  return snapshot;
}

export function useBackgroundMediaUpload(): BackgroundUploadSnapshot {
  return React.useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}
