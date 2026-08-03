import type { QueuedMediaAttachment } from "@/features/messages/lib/backgroundMediaUploadStore";
import { enqueueBackgroundMediaUpload } from "@/features/messages/lib/backgroundMediaUploadStore";
import {
  buildOutgoingMessage,
  type ImetaMedia,
  mergeOutgoingTags,
} from "@/features/messages/lib/imetaMediaMarkdown";
import { diffAddedMentionPubkeys } from "@/features/messages/lib/threading";
import { buildCustomEmojiTags } from "@/shared/lib/customEmojiTags";
import type { CustomEmoji } from "@/shared/lib/remarkCustomEmoji";

type EditDraft = {
  content: string;
  pendingImeta: ImetaMedia[];
  queuedAttachments: QueuedMediaAttachment[];
  spoileredAttachmentUrls: Set<string>;
};

type SubmitMessageEditOptions = EditDraft & {
  clearComposer: () => void;
  customEmoji: ReadonlyArray<CustomEmoji>;
  extractMentionPubkeys: (content: string) => string[];
  originalContent: string;
  ownerPubkey: string | null;
  restoreComposer: (draft: EditDraft) => void;
  save: (
    content: string,
    mediaTags?: string[][],
    mentionPubkeys?: string[],
  ) => Promise<void>;
  setUploadError: (message: string) => void;
};

/** Clear an edited message immediately, then upload and save captured state. */
export async function submitMessageEdit({
  clearComposer,
  content,
  customEmoji,
  extractMentionPubkeys,
  originalContent,
  ownerPubkey,
  pendingImeta,
  queuedAttachments,
  restoreComposer,
  save,
  setUploadError,
  spoileredAttachmentUrls,
}: SubmitMessageEditOptions): Promise<void> {
  const draft: EditDraft = {
    content,
    pendingImeta: [...pendingImeta],
    queuedAttachments: [...queuedAttachments],
    spoileredAttachmentUrls: new Set(spoileredAttachmentUrls),
  };
  const addedMentionPubkeys = diffAddedMentionPubkeys(
    extractMentionPubkeys(originalContent),
    extractMentionPubkeys(content),
    ownerPubkey ?? "",
  );
  clearComposer();

  const finishEdit = async (uploaded: ImetaMedia[]) => {
    // An explicit empty media tag set tells edit receivers to wipe attachments.
    const { content: finalContent, mediaTags } = buildOutgoingMessage(
      content,
      [...draft.pendingImeta, ...uploaded],
      draft.spoileredAttachmentUrls,
    );
    const outgoingTags =
      mergeOutgoingTags(
        mediaTags,
        buildCustomEmojiTags(finalContent, customEmoji),
      ) ?? [];
    await save(finalContent, outgoingTags, addedMentionPubkeys);
  };

  if (draft.queuedAttachments.length > 0) {
    enqueueBackgroundMediaUpload({
      attachments: draft.queuedAttachments,
      onComplete: async (uploaded) => {
        try {
          await finishEdit(uploaded);
        } catch {
          restoreComposer(draft);
        }
      },
      onError: (error) => {
        restoreComposer(draft);
        setUploadError(String(error));
      },
    });
    return;
  }

  try {
    await finishEdit([]);
  } catch {
    restoreComposer(draft);
  }
}
