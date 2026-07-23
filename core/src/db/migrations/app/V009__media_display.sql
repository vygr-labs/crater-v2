-- App schema v9 — per-item image/video display options.
--
-- Media items now carry their own presentation state so the operator can
-- decide, per image/video, how it frames on the projection output:
--   • fit_mode — how the media maps to the 16:9 projection canvas:
--       'default' → follow the global default (SettingsService.mediaDefaultFit)
--       'contain' → letterbox, whole frame visible (PreserveAspectFit)
--       'cover'   → fill the canvas, overflow cropped (PreserveAspectCrop)
--       'stretch' → fill exactly, source aspect ignored (Stretch)
--   • crop_x/y/w/h — a persisted normalized (0..1) crop rectangle applied
--     before fit. {0,0,1,1} = whole frame (no crop). Set from the media edit
--     modal's crop tool; used as the default framing when the item goes live.
--   • loop_video — whether a video restarts at end (1) or plays once and holds
--     its last frame (0). Default 1 preserves the prior always-loop behavior.
--     Meaningless for images / PDFs.
--   • muted — force-mute this item's audio regardless of live-audio routing
--     (0 = follow normal routing, 1 = never sound). Meaningless for images /
--     PDFs.
--
-- Every column is an additive ADD COLUMN whose default reproduces the
-- pre-migration behavior, so existing rows render exactly as before until the
-- operator edits them. SQLite applies these in one implicit transaction from
-- the migration runner; no table recreate is needed (unlike V005, which had to
-- rewrite a CHECK constraint).
ALTER TABLE media ADD COLUMN fit_mode   TEXT    NOT NULL DEFAULT 'default';
ALTER TABLE media ADD COLUMN crop_x     REAL    NOT NULL DEFAULT 0.0;
ALTER TABLE media ADD COLUMN crop_y     REAL    NOT NULL DEFAULT 0.0;
ALTER TABLE media ADD COLUMN crop_w     REAL    NOT NULL DEFAULT 1.0;
ALTER TABLE media ADD COLUMN crop_h     REAL    NOT NULL DEFAULT 1.0;
ALTER TABLE media ADD COLUMN loop_video INTEGER NOT NULL DEFAULT 1 CHECK (loop_video IN (0, 1));
ALTER TABLE media ADD COLUMN muted      INTEGER NOT NULL DEFAULT 0 CHECK (muted IN (0, 1));
