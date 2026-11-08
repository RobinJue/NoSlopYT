# tv-probe (Phase 0)

Throwaway command-line probe for the YouTube recommendations work in No Slop. It signs in to a throwaway Google
account with YouTube's TV code flow and tries Home, the card menu, watch reporting and Up next, printing only
status codes, key names and counts. Python 3.9, standard library only: run it with `/usr/bin/python3 -I`.

State (tokens, device code, raw captures, `log.jsonl`) lives outside the repo in `$NOSLOP_PROBE_DIR`
(default `~/.noslop-tv-probe`, folder 0700, files 0600). `probe.py revoke` deletes it. Only `www.youtube.com`,
`youtubei.googleapis.com` and `oauth2.googleapis.com` are ever contacted; redirects are not followed.

Run order (plan Task 7), with the owner:
1. `signin start`, approve the code in a browser on the throwaway account, `signin wait`, `refresh`.
2. `home --capture home1 --shelf`, then the Home variants; `menu` and `feedback` on one video.
3. `report` three fresh videos, `history` after 2 and 5 minutes; `next` on a seeded-topic video.
4. `home` again hours later; `fixture` for each capture; `results`.
5. `revoke` and confirm the state folder is gone.

Tests: `/usr/bin/python3 -I -m unittest discover -s scripts/tv-probe/tests -t scripts/tv-probe -v`

Commands added last: `next --video ID` (signed and anonymous Up next, counts and overlap), `fixture --capture NAME --out PATH
[--hide-titles]` (scrubbed copy of a capture; exit 2 and nothing written when the leak check finds anything), `results`
(Markdown pass-rule summary from `log.jsonl`: Home 2 of 3 tries, each with 8 visible videos and a working continuation; Reporting 3 of 3 videos within 5 minutes; Card actions needs a menu with both Not interested and Don't recommend and an accepted feedback call).

Capture names for `fixture --capture`: `<home --capture NAME>-1`, `-2`, `-shelf`; `panel-<videoId>` (menu, feedback); `player-<videoId>` (report); `history-<videoId>` (history); `next-signed`, `next-anon` (next).

`revoke` revokes the tokens when there are any, then always wipes the state folder, and exits 1 if it could not. It only deletes a folder holding the probe's own `.noslop-probe` marker and never follows a symlink.
