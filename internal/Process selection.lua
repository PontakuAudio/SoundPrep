-- @description SoundPrep internal selection processor (invoked by the native helper)
-- Auditioning must not add automatic Undo points. The empty deferred callback
-- only suppresses Undo; playback below is synchronous. If another selection
-- arrives before that callback, restart this inert VM without a running-script
-- dialog. Native preview ownership lives in the handoff, never in this VM.
reaper.set_action_options(3)
reaper.defer(function()end)
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]internal[/\\]')
package.path=root..'/lib/?.lua;'..package.path
require('am.selection').dispatch(reaper)
