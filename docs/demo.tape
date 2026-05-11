# vhs tape for the sandbox-manager README demo.
#
# Run with:   vhs docs/demo.tape
# Or (recommended) via the wrapper that handles prereqs & cleanup:
#             ./docs/record-demo.sh
#
# Produces:   docs/demo.gif

Output docs/demo.gif

# --- Terminal geometry & look ---
Set FontSize    14
Set Width       1200
Set Height      720
Set Padding     20
Set Theme       "Catppuccin Mocha"
Set TypingSpeed 45ms

# --- Quiet shell setup we don't want on camera ---
Hide
Type `export PS1='$ ' PS2='> ' HISTFILE=/dev/null PROMPT_COMMAND=''`
Enter
Type "clear"
Enter
Show

# --- 1. Create a Debian sandbox ---
Type "sandbox create debian:trixie demo"
Sleep 400ms
Enter
# Wait for the success banner; allow up to 3 minutes for a fresh apt run.
Wait+Screen@3m /is ready/
Sleep 2s

# --- 2. Prove it's a real Debian box ---
Type "sandbox exec demo cat /etc/os-release"
Sleep 400ms
Enter
Wait+Screen /PRETTY_NAME/
Sleep 2s

# --- 3. List sandboxes ---
Type "sandbox list"
Sleep 400ms
Enter
Wait+Screen /demo/
Sleep 2s

# --- 4. Tear it down (purge home dir too, keeps the recording cleanup tidy) ---
Type "sandbox rm --purge demo"
Sleep 400ms
Enter
# Wait for the prompt to come back.
Wait+Screen@30s /\$ $/
Sleep 1500ms
