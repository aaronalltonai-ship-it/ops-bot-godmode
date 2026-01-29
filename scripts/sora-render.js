import { chromium } from  playwright;
import path from path;

function getArgValue(flag) {
  const index = process.argv.indexOf(flag);
  if (index >= 0 && index < process.argv.length - 1) {
    return process.argv[index + 1];
  }
  return undefined;
}

const prompt = getArgValue(--prompt) || ;
const taskId = getArgValue(--taskId) || ;
const htmlPath = getArgValue(--html) || D:/Sora.html;

if (!prompt) {
  console.error(Missing --prompt);
  process.exit(1);
}

const resolvedHtml = path.isAbsolute(htmlPath)
  ? htmlPath
  : path.resolve(process.cwd(), htmlPath);
const htmlUrl = ile://;

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(htmlUrl, { waitUntil: domcontentloaded, timeout: 60000 });
    const textArea = page.locator('textarea[placeholder=Describe your video...]');
    await textArea.fill(prompt);
    const button = page.getByRole(button, { name: /Create video/i }).first();
    await button.click();
    const video = page.locator(video).first();
    await video.waitFor({ state: attached, timeout: 120000 });
    await page.waitForTimeout(4000);
    const videoSrc = await video.getAttribute(src);
    if (!videoSrc) {
      throw new Error(Video element rendered but no src detected);
    }
    console.log(JSON.stringify({ success: true, taskId, videoSrc }));
    await browser.close();
    process.exit(0);
  } catch (error) {
    await browser.close();
    console.log(JSON.stringify({ success: false, taskId, error: String(error) }));
    process.exit(1);
  }
})();
