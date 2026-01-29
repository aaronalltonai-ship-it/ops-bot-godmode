# Ops-Bot God Mode Repo

This repository packages the GodMode-enabled watcher along with a sample Cody dispatcher.

## Included files
- ops-bot-watch.ps1 — copy of the GodMode-aware watcher that retries failed tasks until completion.
- cody-dispatch.ps1 — sample wrapper to forward prompts to the Cody CLI (replace cody-cli with your actual command).

## Setup
1. Copy this repo into your workspace or keep it alongside the production watcher.
2. Update cody-dispatch.ps1 to call your actual Cody CLI/endpoint (see placeholders).
3. Configure D:\online-store\.env.local:
   `
   OPS_BOT_DISPATCH=D:\workspace\ops-bot-godmode-repo\cody-dispatch.ps1
   OPS_BOT_CONFIG=D:\workspace\ops-bot\config.yaml  # if needed
   `
4. Run the watcher with log-friendly flags:
   `powershell
   powershell -NoLogo -File D:\workspace\ops-bot-godmode-repo\ops-bot-watch.ps1 -GodMode -AgentName cody
   `
5. Ensure Git trusts this workspace if you start mirroring outputs elsewhere (see git config --global --add safe.directory <path>).

