# Ops-Bot God Mode Repo

This repository packages the GodMode-enabled watcher along with a sample Cody dispatcher.

## Included files
- ops-bot-watch.ps1 — GodMode watcher that retries failed tasks/scans and mirrors artifacts.
- cody-dispatch.ps1 — sample dispatcher stub (replace the cody-cli call with your own agent).
- scripts/sora-render.js — launches the saved Sora web app locally, fills the prompt, and clicks the create button.

## Setup
1. Copy this repo into your workspace or keep it alongside the production watcher.
2. Install the Node dependencies so the Sora automation can run:
   `ash
   cd D:\workspace\ops-bot-godmode-repo
   npm install
   `
3. Update cody-dispatch.ps1 to run the actual Cody bot CLI (replace the placeholder command).
4. Configure D:\online-store\.env.local with the dispatcher and Sora helpers:
   `ini
   OPS_BOT_DISPATCH=D:\workspace\ops-bot-godmode-repo\cody-dispatch.ps1
   OPS_BOT_CONFIG=D:\workspace\ops-bot\config.yaml  # if your dispatcher needs config
   SORA_RENDER_SCRIPT=D:\workspace\ops-bot-godmode-repo\scripts\sora-render.js
   SORA_RENDER_HTML=D:\Sora.html
   `
5. Run the watcher with the desired agent name (GodMode keeps retrying until Cody/Sora finish):
   `powershell
   powershell -NoLogo -File D:\workspace\ops-bot-godmode-repo\ops-bot-watch.ps1 -GodMode -AgentName cody-bot
   `
6. Make sure Git trusts this workspace if you mirror artifacts elsewhere (see git config --global --add safe.directory <path>).
