#!/usr/bin/env node
// Manage OAuth tokens for all configured accounts.
//
// Usage:
//   node tokens.js capture              # Save current session's tokens under its email
//   node tokens.js capture-all          # Interactive: authenticate each account and save tokens
//   node tokens.js swap <email>         # Write <email>'s tokens into the keychain
//   node tokens.js list                 # Show which accounts have stored tokens
//   node tokens.js status               # Show current keychain account

const { execFileSync, spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DATA_DIR = path.join(__dirname, "..", "data");
const TOKENS_FILE = path.join(DATA_DIR, "tokens.json");
// Can be overridden via SUPERPOWERD_KEYCHAIN_SERVICE for test runs against a
// throwaway keychain entry — production always uses "Claude Code-credentials".
const KEYCHAIN_SERVICE = process.env.SUPERPOWERD_KEYCHAIN_SERVICE || "Claude Code-credentials";

// macOS keeps credentials in the login keychain; Linux/WSL keeps them in a
// 0600 JSON file. Override the path with SUPERPOWERD_CREDENTIALS_FILE.
const IS_DARWIN = process.platform === "darwin";
const CREDENTIALS_FILE = process.env.SUPERPOWERD_CREDENTIALS_FILE
  || path.join(os.homedir(), ".claude", ".credentials.json");

// Identity lives separately from the tokens: ~/.claude.json carries the
// oauthAccount record (email, org) that `claude auth status` reports. Swapping
// tokens without swapping this leaves the CLI insisting it's still the old
// account, and any later capture files the new token under the old email.
const CLAUDE_CONFIG_FILE = process.env.SUPERPOWERD_CLAUDE_CONFIG
  || path.join(os.homedir(), ".claude.json");

function log(message) {
  console.log("[" + new Date().toISOString() + "] " + message);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function readTokenStore() {
  if (!fs.existsSync(TOKENS_FILE)) return {};
  try { return JSON.parse(fs.readFileSync(TOKENS_FILE, "utf8")); } catch { return {}; }
}

function writeTokenStore(store) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.writeFileSync(TOKENS_FILE, JSON.stringify(store, null, 2) + "\n", { mode: 0o600 });
}

function readKeychain() {
  try {
    if (!IS_DARWIN) {
      return JSON.parse(fs.readFileSync(CREDENTIALS_FILE, "utf8"));
    }
    const password = execFileSync(
      "security", ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
      { encoding: "utf8", timeout: 5000 }
    ).trim();
    return JSON.parse(password);
  } catch {
    return null;
  }
}

function writeKeychain(data, account) {
  const json = JSON.stringify(data);
  if (!IS_DARWIN) {
    // Write via a 0600 temp file + rename so a crash can't leave Claude Code
    // with a half-written credentials file.
    const tmp = CREDENTIALS_FILE + ".superpowerd.tmp";
    fs.mkdirSync(path.dirname(CREDENTIALS_FILE), { recursive: true });
    fs.writeFileSync(tmp, json, { mode: 0o600 });
    fs.renameSync(tmp, CREDENTIALS_FILE);
    return;
  }
  execFileSync("security", [
    "add-generic-password", "-U",
    "-s", KEYCHAIN_SERVICE,
    "-a", account || os.userInfo().username,
    "-w", json,
  ], { timeout: 5000 });
}

function getKeychainAccount() {
  // Only meaningful on macOS, where the keychain entry carries an account name.
  if (!IS_DARWIN) return null;
  try {
    const output = execFileSync(
      "security", ["find-generic-password", "-s", KEYCHAIN_SERVICE],
      { encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"] }
    );
    const match = output.match(/"acct"<blob>="([^"]+)"/);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

function readAccountRecord() {
  try {
    const config = JSON.parse(fs.readFileSync(CLAUDE_CONFIG_FILE, "utf8"));
    return config.oauthAccount || null;
  } catch {
    return null;
  }
}

function writeAccountRecord(account) {
  // ~/.claude.json holds far more than identity (project state, history), so
  // rewrite only oauthAccount and preserve everything else. Atomic rename, and
  // keep the file's existing mode rather than assuming one.
  const raw = fs.readFileSync(CLAUDE_CONFIG_FILE, "utf8");
  const config = JSON.parse(raw);
  config.oauthAccount = account;
  const mode = fs.statSync(CLAUDE_CONFIG_FILE).mode & 0o777;
  const tmp = CLAUDE_CONFIG_FILE + ".superpowerd.tmp";
  fs.writeFileSync(tmp, JSON.stringify(config, null, 2) + "\n", { mode });
  fs.renameSync(tmp, CLAUDE_CONFIG_FILE);
}

function getCurrentEmail() {
  try {
    const result = execFileSync("claude", ["auth", "status"], { encoding: "utf8", timeout: 5000 });
    const data = JSON.parse(result);
    return data.email || null;
  } catch {
    return null;
  }
}

function loadAccounts() {
  const file = path.join(__dirname, "..", "accounts.conf");
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
}

// Capture current session's OAuth tokens and store under the email
async function capture() {
  const credentials = readKeychain();
  if (!credentials || !credentials.claudeAiOauth) {
    console.error("No OAuth credentials found in keychain");
    process.exit(1);
  }

  const email = getCurrentEmail();
  if (!email) {
    console.error("Could not determine current account email");
    process.exit(1);
  }

  // Get org ID from roles endpoint
  let orgId = null;
  try {
    const rolesOutput = execFileSync("curl", [
      "-s", "https://api.anthropic.com/api/oauth/claude_cli/roles",
      "-H", "Authorization: Bearer " + credentials.claudeAiOauth.accessToken,
    ], { encoding: "utf8", timeout: 10000 });
    const roles = JSON.parse(rolesOutput);
    orgId = roles.organization_uuid || null;
  } catch {}

  // Fall back to CLI auth status for org ID
  if (!orgId) {
    try {
      const authOutput = execFileSync("claude", ["auth", "status"], { encoding: "utf8", timeout: 5000 });
      orgId = JSON.parse(authOutput).orgId || null;
    } catch {}
  }

  // The token comes from the credentials file and the email from the config
  // file. If those two have drifted apart, pairing them files a token under
  // the wrong account and silently corrupts the store — refuse instead.
  const account = readAccountRecord();
  if (account && orgId && account.organizationUuid && account.organizationUuid !== orgId) {
    console.error("Refusing to capture: credentials and " + CLAUDE_CONFIG_FILE + " disagree.");
    console.error("  token belongs to org : " + orgId);
    console.error("  config claims account: " + account.emailAddress + " (org " + account.organizationUuid + ")");
    console.error("Run `claude auth login` to resync them, then capture again.");
    process.exit(1);
  }

  const store = readTokenStore();
  store[email] = {
    // Identity travels with the tokens so swap() can restore both together.
    oauthAccount: account,
    accessToken: credentials.claudeAiOauth.accessToken,
    refreshToken: credentials.claudeAiOauth.refreshToken,
    expiresAt: credentials.claudeAiOauth.expiresAt,
    refreshTokenExpiresAt: credentials.claudeAiOauth.refreshTokenExpiresAt,
    scopes: credentials.claudeAiOauth.scopes,
    subscriptionType: credentials.claudeAiOauth.subscriptionType,
    rateLimitTier: credentials.claudeAiOauth.rateLimitTier,
    orgId,
    capturedAt: new Date().toISOString(),
  };
  writeTokenStore(store);
  log("Captured tokens for " + email + (orgId ? " (org: " + orgId + ")" : ""));
}

// Authenticate each account interactively and capture tokens
async function captureAll() {
  const accounts = loadAccounts();
  if (accounts.length === 0) {
    console.error("No accounts in accounts.conf");
    process.exit(1);
  }

  log("Will authenticate " + accounts.length + " accounts one by one.");
  log("Each will open a browser — sign in, then return here.\n");

  for (const email of accounts) {
    // Check if we already have a valid token
    const store = readTokenStore();
    if (store[email] && store[email].accessToken) {
      log(email + " — already captured, skipping (delete from data/tokens.json to re-capture)");
      continue;
    }

    log("Authenticating: " + email);
    log("Running: claude auth login --email " + email);

    // Run claude auth login and wait for completion
    await new Promise((resolve, reject) => {
      const child = spawn("claude", ["auth", "login", "--email", email], {
        stdio: "inherit",
      });
      child.on("close", (code) => {
        if (code === 0) resolve();
        else reject(new Error("Login failed for " + email));
      });
    });

    // Capture the tokens that are now in keychain
    await capture();
    log("");
  }

  log("All accounts captured.");
  await list();
}

// Swap keychain credentials to a different account's tokens
async function swap(email) {
  const store = readTokenStore();
  if (!store[email]) {
    console.error("No stored tokens for " + email);
    console.error("Run: node tokens.js capture-all");
    process.exit(1);
  }

  const credentials = readKeychain();
  if (!credentials) {
    console.error("No existing keychain entry to update");
    process.exit(1);
  }

  // Preserve MCP OAuth tokens, only swap the Claude AI OAuth
  credentials.claudeAiOauth = {
    accessToken: store[email].accessToken,
    refreshToken: store[email].refreshToken,
    expiresAt: store[email].expiresAt,
    scopes: store[email].scopes,
    subscriptionType: store[email].subscriptionType,
    rateLimitTier: store[email].rateLimitTier,
  };
  // Only carry this over when captured — omitting it entirely is safer than
  // writing an undefined that JSON.stringify would drop anyway.
  if (store[email].refreshTokenExpiresAt !== undefined) {
    credentials.claudeAiOauth.refreshTokenExpiresAt = store[email].refreshTokenExpiresAt;
  }

  const keychainAccount = getKeychainAccount();
  writeKeychain(credentials, keychainAccount);

  // Identity must move with the tokens, or `claude auth status` keeps naming
  // the old account and the next capture misfiles the token under it.
  if (store[email].oauthAccount) {
    writeAccountRecord(store[email].oauthAccount);
    log("Swapped credentials and account record to " + email);
  } else {
    log("Swapped credentials to " + email);
    log("WARNING: no stored account record for " + email + " — `claude auth status`");
    log("         will still report the previous account. Re-run capture for this");
    log("         account after `claude auth login` to record its identity.");
  }
}

async function list() {
  const store = readTokenStore();
  const accounts = loadAccounts();
  const current = getCurrentEmail();

  console.log("\nStored tokens:");
  for (const email of accounts) {
    const token = store[email];
    const active = email === current ? " <-- active" : "";
    if (token) {
      const age = Math.floor((Date.now() - new Date(token.capturedAt).getTime()) / 3600000);
      console.log("  [+] " + email + " (captured " + age + "h ago)" + active);
    } else {
      console.log("  [-] " + email + " (not captured)" + active);
    }
  }

  // Captured accounts missing from accounts.conf would otherwise be invisible
  // here and skipped by rotation, which reads the same list.
  const orphans = Object.keys(store).filter((email) => !accounts.includes(email));
  for (const email of orphans) {
    const active = email === current ? " <-- active" : "";
    console.log("  [!] " + email + " (captured, but not in accounts.conf)" + active);
  }
  if (orphans.length > 0) {
    console.log("\n  Add the [!] account(s) to accounts.conf to include them in rotation.");
  }
  console.log("");
}

async function status() {
  const credentials = readKeychain();
  if (!credentials || !credentials.claudeAiOauth) {
    console.log("No OAuth credentials in keychain");
    return;
  }
  const email = getCurrentEmail();
  const expires = new Date(credentials.claudeAiOauth.expiresAt);
  const remaining = Math.floor((expires.getTime() - Date.now()) / 60000);

  // Cross-check the token's real owner against the identity the CLI reports.
  const account = readAccountRecord();
  const store = readTokenStore();
  const owner = Object.keys(store).find(
    (e) => store[e].accessToken === credentials.claudeAiOauth.accessToken
  );
  if (account && owner && account.emailAddress !== owner) {
    console.log("WARNING: credentials and account record disagree.");
    console.log("  token matches stored account: " + owner);
    console.log("  but config reports          : " + account.emailAddress);
    console.log("  Run `claude auth login` to resync before capturing again.");
    console.log("");
  }

  console.log("Keychain account: " + (email || "unknown"));
  console.log("Token expires: " + expires.toISOString() + " (" + remaining + " min)");
  console.log("Subscription: " + credentials.claudeAiOauth.subscriptionType);
  console.log("Rate limit tier: " + credentials.claudeAiOauth.rateLimitTier);
}

async function main() {
  const command = process.argv[2];
  const argument = process.argv[3];

  switch (command) {
    case "capture":
      await capture();
      break;
    case "capture-all":
      await captureAll();
      break;
    case "swap":
      if (!argument) {
        console.error("Usage: tokens.js swap <email>");
        process.exit(1);
      }
      await swap(argument);
      break;
    case "list":
      await list();
      break;
    case "status":
      await status();
      break;
    default:
      console.error("Usage: tokens.js <capture|capture-all|swap|list|status> [email]");
      console.error("");
      console.error("  capture        Save current session's tokens");
      console.error("  capture-all    Authenticate all accounts and save tokens");
      console.error("  swap <email>   Write tokens for <email> into the keychain");
      console.error("  list           Show which accounts have stored tokens");
      console.error("  status         Show current keychain account");
      process.exit(1);
  }
}

main().catch((error) => {
  console.error("Fatal:", error.message);
  process.exit(1);
});
