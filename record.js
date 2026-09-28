#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const { performance } = require('node:perf_hooks');

const [url, output, fontSizeText, widthText, heightText, chromePath, profileDir, readyPath, format, capturePath] = process.argv.slice(2);
const fontSize = Number(fontSizeText);
const width = Number(widthText);
const height = Number(heightText);
const fps = 30;

if (!url || !output || !fontSize || !width || !height || !chromePath || !profileDir || !readyPath || !format || !capturePath) {
  process.stderr.write('record.js received incomplete arguments\n');
  process.exit(2);
}
if (typeof WebSocket === 'undefined') {
  process.stderr.write('Recording requires Node.js 22 or newer (built-in WebSocket support)\n');
  process.exit(2);
}
if (!['webm', 'mp4', 'gif'].includes(format)) {
  process.stderr.write('Unsupported recording format: ' + format + '\n');
  process.exit(2);
}

let chrome;
let socket;
let encoder;
let encoderExit;
let ffmpegError = '';
let nextId = 0;
let frameQueue = Promise.resolve();
let framePump = Promise.resolve();
let frameTimer;
let pumpingFrames = false;
let startTime = 0;
let stopTime = 0;
let lastFrameIndex = 0;
let lastFrame;
let stopping = false;
let chromeLaunchError;
let captureError;
let resolveStop;
let stopReason;
const stopRequested = new Promise(resolve => {
  resolveStop = resolve;
});

function requestStop(reason) {
  if (stopping) return;
  stopReason = reason;
  stopTime = performance.now();
  resolveStop();
}

process.once('SIGINT', () => requestStop('interrupted'));
process.once('SIGTERM', () => requestStop('terminated'));

const pending = new Map();

function connectDevTools(webSocketUrl) {
  return new Promise((resolve, reject) => {
    socket = new WebSocket(webSocketUrl);
    const timeout = setTimeout(() => reject(new Error('Timed out connecting to Chrome DevTools')), 10000);
    socket.addEventListener('open', () => {
      clearTimeout(timeout);
      resolve();
    }, { once: true });
    socket.addEventListener('error', () => {
      clearTimeout(timeout);
      reject(new Error('Could not connect to Chrome DevTools'));
    }, { once: true });
    socket.addEventListener('close', () => {
      for (const waiter of pending.values()) {
        clearTimeout(waiter.timeout);
        waiter.reject(new Error('Chrome DevTools connection closed'));
      }
      pending.clear();
      if (!stopping) requestStop('browser closed');
    });
    socket.addEventListener('message', event => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      if (message.id) {
        const waiter = pending.get(message.id);
        if (!waiter) return;
        clearTimeout(waiter.timeout);
        pending.delete(message.id);
        if (message.error) waiter.reject(new Error(message.error.message));
        else waiter.resolve(message.result || {});
      } else if (message.method === 'Page.screencastFrame') {
        frameQueue = frameQueue.then(() => handleFrame(message.params)).catch(error => {
          captureError = error;
          requestStop('capture error');
        });
      }
    });
  });
}

function callDevTools(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Chrome DevTools timed out: ${method}`));
    }, 10000);
    pending.set(id, { resolve, reject, timeout });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function waitForPage(chromeProcess, baseUrl, profile) {
  const activePortFile = `${profile}/DevToolsActivePort`;
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (chromeLaunchError) throw chromeLaunchError;
    if (chromeProcess.exitCode !== null) throw new Error('Chrome exited before opening the demo');
    try {
      const lines = fs.readFileSync(activePortFile, 'utf8').trim().split(/\s+/);
      const port = Number(lines[0]);
      if (port > 0) {
        const response = await fetch(`http://127.0.0.1:${port}/json/list`);
        if (response.ok) {
          const pages = await response.json();
          const page = pages.find(target => target.type === 'page' && target.url.startsWith(baseUrl));
          if (page) return page;
        }
      }
    } catch {
      // Chrome creates the DevTools port file and page asynchronously.
    }
    await delay(100);
  }
  throw new Error('Chrome did not open the ttyd page in time');
}

function writeFrame(data) {
  return new Promise((resolve, reject) => {
    if (!encoder || encoder.stdin.destroyed) {
      reject(new Error('FFmpeg input closed unexpectedly'));
      return;
    }
    if (encoder.stdin.write(data)) resolve();
    else encoder.stdin.once('drain', resolve);
  });
}

async function handleFrame(params) {
  try {
    if (!stopping) {
      lastFrame = Buffer.from(params.data, 'base64');
    }
  } finally {
    if (socket && socket.readyState === WebSocket.OPEN) {
      await callDevTools('Page.screencastFrameAck', { sessionId: params.sessionId });
    }
  }
}

function startFramePump() {
  frameTimer = setInterval(() => {
    if (stopping || pumpingFrames || !lastFrame) return;
    pumpingFrames = true;
    framePump = (async () => {
      const targetIndex = Math.round((performance.now() - startTime) * fps / 1000);
      while (!stopping && lastFrameIndex < targetIndex) {
        await writeFrame(lastFrame);
        lastFrameIndex++;
      }
    })().catch(error => {
      captureError = error;
      requestStop('FFmpeg error');
    }).finally(() => {
      pumpingFrames = false;
    });
  }, 1000 / fps);
}

async function closeChrome() {
  if (!chrome || chrome.exitCode !== null) return;
  try {
    if (socket && socket.readyState === WebSocket.OPEN) {
      await callDevTools('Browser.close');
    }
  } catch {
    // The browser can close the DevTools socket before replying.
  }
  if (chrome.exitCode === null) {
    await Promise.race([
      new Promise(resolve => chrome.once('exit', resolve)),
      delay(2000),
    ]);
  }
  if (chrome.exitCode === null) chrome.kill('SIGTERM');
}

async function finalizeEncoder(success) {
  if (!encoder) return 0;
  if (success && lastFrame) {
    const finalFrameIndex = Math.max(lastFrameIndex, Math.round(((stopTime || performance.now()) - startTime) * fps / 1000));
    while (lastFrameIndex < finalFrameIndex) {
      await writeFrame(lastFrame);
      lastFrameIndex++;
    }
  }
  if (encoder.stdin && !encoder.stdin.destroyed) encoder.stdin.end();
  const result = await encoderExit;
  if (result.code !== 0) {
    if (ffmpegError) process.stderr.write(ffmpegError);
    throw new Error('FFmpeg exited with status ' + (result.code ?? result.signal));
  }
  return result.code;
}

function encodeGif() {
  return new Promise((resolve, reject) => {
    const args = [
      '-n', '-hide_banner', '-loglevel', 'error',
      '-i', capturePath,
      '-filter_complex',
      '[0:v]fps=15,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse[v]',
      '-map', '[v]', '-loop', '0', '-f', 'gif', output,
    ];
    const gifProcess = spawn(process.env.FFMPEG || 'ffmpeg', args, {
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    let gifError = '';
    gifProcess.stderr.on('data', chunk => {
      gifError = (gifError + chunk.toString()).slice(-4000);
    });
    gifProcess.once('error', reject);
    gifProcess.once('close', (code, signal) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error('FFmpeg GIF conversion failed with status ' + (code ?? signal) +
          (gifError ? '\n' + gifError : '')));
      }
    });
  });
}

async function main() {
  let failure;
  let success = false;
  try {
    chrome = spawn(chromePath, [
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-mode',
      '--remote-debugging-address=127.0.0.1',
      '--remote-debugging-port=0',
      `--user-data-dir=${profileDir}`,
      `--window-size=${width},${height}`,
      `--app=${url}`,
    ], { stdio: 'ignore' });
    chrome.once('error', error => { chromeLaunchError = error; });

    const page = await waitForPage(chrome, url, profileDir);
    await connectDevTools(page.webSocketDebuggerUrl);
    const cdp = callDevTools;
    socket.addEventListener('close', () => requestStop('browser closed'));
    await cdp('Page.enable');
    await cdp('Runtime.enable');
    await cdp('Emulation.setDeviceMetricsOverride', {
      width,
      height,
      deviceScaleFactor: 1,
      mobile: false,
      screenWidth: width,
      screenHeight: height,
    });

    const readyDeadline = Date.now() + 15000;
    let pageReady = false;
    while (Date.now() < readyDeadline) {
      const result = await cdp('Runtime.evaluate', {
        expression: "document.readyState === 'complete' && !!document.querySelector('.xterm')",
        returnByValue: true,
      });
      if (result.result && result.result.value) {
        pageReady = true;
        break;
      }
      await delay(100);
    }
    if (!pageReady) throw new Error('The ttyd terminal did not finish loading');

    const imageFormat = format === 'gif' ? 'png' : 'jpeg';
    const imageCodec = format === 'gif' ? 'png' : 'mjpeg';
    const encoderArgs = [
      '-n', '-hide_banner', '-loglevel', 'error',
      '-f', 'image2pipe', '-framerate', String(fps), '-vcodec', imageCodec, '-i', 'pipe:0',
      '-an', '-vf', 'scale=' + width + ':' + height + ':flags=lanczos,setsar=1',
    ];
    if (format === 'webm') {
      encoderArgs.push(
        '-c:v', 'libvpx-vp9', '-deadline', 'realtime', '-cpu-used', '8',
        '-crf', '32', '-b:v', '0', '-pix_fmt', 'yuv420p', '-f', 'webm', output,
      );
    } else if (format === 'mp4') {
      encoderArgs.push(
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
        '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-f', 'mp4', output,
      );
    } else {
      encoderArgs.push(
        '-c:v', 'ffv1', '-pix_fmt', 'bgr0', '-f', 'matroska', capturePath,
      );
    }
    encoder = spawn(process.env.FFMPEG || 'ffmpeg', encoderArgs, { stdio: ['pipe', 'ignore', 'pipe'] });
    encoderExit = new Promise((resolve, reject) => {
      encoder.once('error', reject);
      encoder.once('close', (code, signal) => resolve({ code, signal }));
      encoder.stderr.on('data', chunk => {
        ffmpegError = (ffmpegError + chunk.toString()).slice(-4000);
      });
    });
    encoderExit.catch(error => {
      captureError = error;
      requestStop('FFmpeg error');
    });

    const screenshotOptions = { format: imageFormat, fromSurface: true };
    if (imageFormat === 'jpeg') screenshotOptions.quality = 85;
    const initial = await cdp('Page.captureScreenshot', screenshotOptions);
    lastFrame = Buffer.from(initial.data, 'base64');
    startTime = performance.now();
    await writeFrame(lastFrame);
    const screencastOptions = {
      format: imageFormat,
      maxWidth: width,
      maxHeight: height,
      everyNthFrame: 1,
    };
    if (imageFormat === 'jpeg') screencastOptions.quality = 85;
    await cdp('Page.startScreencast', screencastOptions);
    startFramePump();
    fs.writeFileSync(readyPath, 'ready\n');

    await stopRequested;
    stopping = true;
    clearInterval(frameTimer);
    await framePump;
    await frameQueue;
    await cdp('Page.stopScreencast').catch(() => {});
    if (captureError) throw captureError;
    success = true;
  } catch (error) {
    failure = error;
  }

  stopping = true;
  await closeChrome();
  if (socket && socket.readyState === WebSocket.OPEN) socket.close();
  try {
    await finalizeEncoder(success);
    if (success && format === 'gif') await encodeGif();
  } catch (error) {
    failure ||= error;
  }
  if (format === 'gif') {
    try { fs.rmSync(capturePath, { force: true }); } catch {}
  }
  if (stopReason && stopReason !== 'interrupted' && !failure) {
    failure = new Error(`Recording stopped because ${stopReason}`);
  }
  if (failure) {
    try { fs.rmSync(output, { force: true }); } catch {}
    if (format === 'gif') {
      try { fs.rmSync(capturePath, { force: true }); } catch {}
    }
    throw failure;
  }
}

main().catch(error => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
