#!/bin/bash

# ============================================================
# SPELLDUEL - AI SPELLING GAME INSTALLER
# Removes old ai-code-editor, builds new spelling game app
# Keeps: nginx, ollama
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"; }

INSTALL_DIR="$HOME/spellduel"
WWW_DIR="/var/www/spellduel"

print_banner() {
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║        🎯 SPELLDUEL INSTALLER                    ║"
  echo "  ║   AI Spelling Game · TTS · Lobby · Leaderboard  ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ============================================================
# STEP 1: CLEANUP OLD INSTALLATION
# ============================================================
cleanup_old() {
  section "Removing Old ai-code-editor Installation"

  # Stop and remove PM2 processes
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  if command -v pm2 &>/dev/null; then
    info "Stopping old PM2 processes..."
    pm2 delete ai-code-editor-backend 2>/dev/null && log "Removed ai-code-editor-backend from PM2" || true
    pm2 delete all 2>/dev/null || true
    pm2 save --force 2>/dev/null || true
  fi

  # Remove old app directory
  if [ -d "$HOME/ai-code-editor" ]; then
    rm -rf "$HOME/ai-code-editor"
    log "Removed ~/ai-code-editor"
  fi

  # Remove old www
  if [ -d "/var/www/ai-code-editor" ]; then
    rm -rf "/var/www/ai-code-editor"
    log "Removed /var/www/ai-code-editor"
  fi

  # Remove old nginx config
  rm -f /etc/nginx/sites-enabled/ai-code-editor 2>/dev/null || true
  rm -f /etc/nginx/sites-available/ai-code-editor 2>/dev/null || true
  log "Removed old nginx config"

  log "Old installation cleaned up"
}

# ============================================================
# STEP 2: CHECK PREREQUISITES
# ============================================================
check_prereqs() {
  section "Checking Prerequisites"

  [[ $EUID -ne 0 ]] && error "Run as root: sudo bash install_spellduel.sh"

  command -v nginx &>/dev/null || error "Nginx not found. Install: apt-get install -y nginx"
  log "Nginx: $(nginx -v 2>&1 | head -1)"

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  command -v node &>/dev/null || error "Node.js not found. Install nvm + node first."
  log "Node.js: $(node -v)"

  command -v npm &>/dev/null || error "npm not found"
  log "npm: $(npm -v)"

  # Install PM2 if missing
  if ! command -v pm2 &>/dev/null; then
    info "Installing PM2..."
    npm install -g pm2
  fi
  log "PM2: $(pm2 --version)"

  # Check Ollama
  if command -v ollama &>/dev/null; then
    log "Ollama: found"
  else
    warn "Ollama not found — AI word generation will use fallback word lists"
  fi
}

# ============================================================
# STEP 3: CREATE PROJECT STRUCTURE
# ============================================================
create_structure() {
  section "Creating SpellDuel Project Structure"

  mkdir -p "$INSTALL_DIR"/{backend/src,frontend/src/{components,pages,hooks,lib},logs}
  mkdir -p "$WWW_DIR"
  log "Directory structure created at $INSTALL_DIR"
}

# ============================================================
# STEP 4: CREATE BACKEND
# ============================================================
create_backend() {
  section "Building Backend (Node.js + WebSocket)"

  # package.json
  cat > "$INSTALL_DIR/backend/package.json" << 'EOF'
{
  "name": "spellduel-backend",
  "version": "1.0.0",
  "main": "src/index.js",
  "scripts": { "start": "node src/index.js", "dev": "node src/index.js" },
  "dependencies": {
    "express": "^4.18.2",
    "ws": "^8.16.0",
    "cors": "^2.8.5",
    "uuid": "^9.0.0",
    "node-fetch": "^3.3.2",
    "better-sqlite3": "^9.4.3"
  }
}
EOF

  # Main server
  cat > "$INSTALL_DIR/backend/src/index.js" << 'SERVEREOF'
const express = require('express');
const { WebSocketServer } = require('ws');
const http = require('http');
const cors = require('cors');
const { v4: uuidv4 } = require('uuid');
const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const app = express();
app.use(cors());
app.use(express.json());

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

// ── SQLite Database ───────────────────────────────────────
const DB_PATH = path.join(__dirname, '..', 'spellduel.db');
const db = new Database(DB_PATH);

db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL COLLATE NOCASE,
    score INTEGER DEFAULT 0,
    games_played INTEGER DEFAULT 0,
    best_score INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_login INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
  CREATE INDEX IF NOT EXISTS idx_users_last_login ON users(last_login);
`);

// ── Auto-delete users inactive > 30 days ─────────────────
function purgeInactiveUsers() {
  const cutoff = Date.now() - (30 * 24 * 60 * 60 * 1000);
  const result = db.prepare('DELETE FROM users WHERE last_login < ?').run(cutoff);
  if (result.changes > 0) {
    info(`Purged ${result.changes} inactive user(s) (>30 days)`);
  }
}
purgeInactiveUsers();
// Run purge every 6 hours
setInterval(purgeInactiveUsers, 6 * 60 * 60 * 1000);

// ── User helpers ──────────────────────────────────────────
function loginOrRegister(username) {
  const now = Date.now();
  const existing = db.prepare('SELECT * FROM users WHERE username = ?').get(username);
  if (existing) {
    db.prepare('UPDATE users SET last_login = ? WHERE id = ?').run(now, existing.id);
    return { ...existing, last_login: now, isNew: false };
  } else {
    const info2 = db.prepare(
      'INSERT INTO users (username, score, games_played, best_score, created_at, last_login) VALUES (?,0,0,0,?,?)'
    ).run(username, now, now);
    return { id: info2.lastInsertRowid, username, score: 0, games_played: 0, best_score: 0, created_at: now, last_login: now, isNew: true };
  }
}

function updateUserScore(username, addScore) {
  const now = Date.now();
  db.prepare(`
    UPDATE users SET
      score = score + ?,
      games_played = games_played + 1,
      best_score = MAX(best_score, ?),
      last_login = ?
    WHERE username = ?
  `).run(addScore, addScore, now, username);
}

function getLeaderboard(limit = 10) {
  return db.prepare('SELECT username, score, games_played, best_score FROM users ORDER BY score DESC LIMIT ?').all(limit);
}

// ── In-Memory State ──────────────────────────────────────
const lobbies = new Map();       // lobbyId → lobby object
const players = new Map();       // ws → player object

// ── Fallback word lists by difficulty ───────────────────
const WORDS = {
  easy: ['cat','dog','sun','hat','pen','box','run','red','big','cup','map','fan','hop','zip','ant'],
  medium: ['planet','jungle','rocket','bridge','flower','castle','dragon','silver','winter','garden'],
  hard: ['phenomenon','questionnaire','Mediterranean','bureaucracy','idiosyncrasy','onomatopoeia']
};

// ── Ollama AI word generation ────────────────────────────
async function generateWordWithAI(difficulty) {
  try {
    const fetch = (await import('node-fetch')).default;
    const prompt = `Give me ONE English ${difficulty} spelling word. Reply with ONLY that single word, lowercase, no spaces, no punctuation, no explanation.`;
    
    const res = await fetch('http://localhost:11434/api/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'phi3:mini', prompt, stream: false }),
      signal: AbortSignal.timeout(8000)
    });
    
    if (!res.ok) throw new Error('Ollama error');
    const data = await res.json();
    // Strip everything: take FIRST word only, remove non-alpha, lowercase
    const word = data.response.trim()
      .split(/[\s\n\r.,!?;:"'()]+/)[0]
      .toLowerCase()
      .replace(/[^a-z]/g, '');
    if (word.length >= 2 && word.length <= 20) return word;
    throw new Error('Invalid word from AI');
  } catch (e) {
    // Fallback to word list
    const list = WORDS[difficulty] || WORDS.medium;
    return list[Math.floor(Math.random() * list.length)];
  }
}

// ── Generate sentence/hint for a word ────────────────────
async function generateHint(word, difficulty) {
  try {
    const fetch = (await import('node-fetch')).default;
    const prompt = `Write ONE short sentence (max 12 words) using the word "${word}". Output ONLY the sentence, nothing else.`;
    
    const res = await fetch('http://localhost:11434/api/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'phi3:mini', prompt, stream: false }),
      signal: AbortSignal.timeout(8000)
    });
    
    if (!res.ok) throw new Error('');
    const data = await res.json();
    // Take only the first sentence
    const hint = data.response.trim().replace(/"/g, '').split(/\n/)[0].split(/\.\s/)[0];
    return hint.length > 5 ? hint : `${word}.`;
  } catch(e) {
    return `${word}.`;
  }
}

// ── Translation Mode: generate phrase ────────────────────
async function generateTranslationChallenge(sourceLang, targetLang, minWords, maxWords) {
  try {
    const fetch = (await import('node-fetch')).default;
    const prompt = `Generate ONE simple ${sourceLang} phrase or sentence with EXACTLY between ${minWords} and ${maxWords} words. Output ONLY the ${sourceLang} phrase, nothing else, no translation, no explanation.`;

    const res = await fetch('http://localhost:11434/api/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'phi3:mini', prompt, stream: false }),
      signal: AbortSignal.timeout(10000)
    });
    if (!res.ok) throw new Error('Ollama error');
    const data = await res.json();
    // Take only first line, strip quotes
    const phrase = data.response.trim().replace(/^["'`]+|["'`]+$/g, '').split('\n')[0].trim();
    const wordCount = phrase.split(/\s+/).length;
    if (wordCount >= minWords && wordCount <= maxWords + 2) return phrase;
    throw new Error('Word count mismatch');
  } catch(e) {
    // Fallback simple phrases
    const fallbacks = {
      english: ['I love to read books', 'The sun is bright today', 'She runs every morning', 'We eat dinner together'],
      indonesian: ['Saya suka membaca buku', 'Matahari sangat cerah', 'Dia berlari setiap pagi', 'Kami makan malam bersama'],
      spanish: ['Me gusta leer libros', 'El sol brilla hoy', 'Ella corre cada mañana', 'Comemos juntos'],
      french: ['J\'aime lire des livres', 'Le soleil brille', 'Elle court chaque matin', 'Nous mangeons ensemble'],
      japanese: ['本を読むのが好きです', '今日は晴れています', '彼女は毎朝走ります', '一緒に夕食を食べます'],
      german: ['Ich lese gerne Bücher', 'Die Sonne scheint hell', 'Sie läuft jeden Morgen', 'Wir essen zusammen'],
      arabic: ['أحب قراءة الكتب', 'الشمس مشرقة اليوم', 'هي تركض كل صباح', 'نأكل العشاء معاً'],
      mandarin: ['我喜欢读书', '今天阳光明媚', '她每天早上跑步', '我们一起吃晚饭'],
    };
    const key = sourceLang.toLowerCase().replace(/\s+/g,'');
    const list = fallbacks[key] || fallbacks['english'];
    return list[Math.floor(Math.random() * list.length)];
  }
}

async function checkTranslation(sourcePhrase, userAnswer, sourceLang, targetLang) {
  try {
    const fetch = (await import('node-fetch')).default;
    const prompt = `You are a translation judge. The ${sourceLang} phrase is: "${sourcePhrase}". The user's ${targetLang} translation is: "${userAnswer}". Judge if it is: CORRECT (meaning fully preserved), CLOSE (minor mistakes but understandable), or WRONG (meaning lost or incorrect). Reply with ONLY one word: CORRECT, CLOSE, or WRONG.`;

    const res = await fetch('http://localhost:11434/api/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'phi3:mini', prompt, stream: false }),
      signal: AbortSignal.timeout(10000)
    });
    if (!res.ok) throw new Error('');
    const data = await res.json();
    const verdict = data.response.trim().toUpperCase().split(/[\s\n]/)[0];
    if (['CORRECT','CLOSE','WRONG'].includes(verdict)) return verdict;
    return 'WRONG';
  } catch(e) {
    // Simple fallback: exact match
    return userAnswer.trim().toLowerCase() === sourcePhrase.trim().toLowerCase() ? 'CORRECT' : 'WRONG';
  }
}

// ── Lobby Management ─────────────────────────────────────
function createLobby(hostId, hostName, settings = {}) {
  const id = Math.random().toString(36).substr(2, 6).toUpperCase();
  const lobby = {
    id,
    hostId,
    name: settings.name || `${hostName}'s Room`,
    difficulty: settings.difficulty || 'medium',
    maxPlayers: settings.maxPlayers || 6,
    players: [],
    status: 'waiting', // waiting | playing | finished
    currentWord: null,
    currentHint: null,
    round: 0,
    maxRounds: settings.maxRounds || 5,
    scores: {},
    createdAt: Date.now()
  };
  lobbies.set(id, lobby);
  return lobby;
}

function getLobbyList() {
  return Array.from(lobbies.values())
    .filter(l => l.status === 'waiting' && l.players.length < l.maxPlayers)
    .map(l => ({
      id: l.id,
      name: l.name,
      difficulty: l.difficulty,
      playerCount: l.players.length,
      maxPlayers: l.maxPlayers,
      maxRounds: l.maxRounds
    }));
}

function broadcast(lobbyId, data, excludeWs = null) {
  const lobby = lobbies.get(lobbyId);
  if (!lobby) return;
  const msg = JSON.stringify(data);
  lobby.players.forEach(playerId => {
    players.forEach((player, ws) => {
      if (player.id === playerId && ws !== excludeWs && ws.readyState === 1) {
        ws.send(msg);
      }
    });
  });
}

function broadcastLobbyList() {
  const list = getLobbyList();
  players.forEach((player, ws) => {
    if (ws.readyState === 1 && !player.lobbyId) {
      ws.send(JSON.stringify({ type: 'lobby_list', lobbies: list }));
    }
  });
}

// ── Game Logic ───────────────────────────────────────────
async function startGame(lobbyId) {
  const lobby = lobbies.get(lobbyId);
  if (!lobby || lobby.players.length < 1) return;

  lobby.status = 'playing';
  lobby.round = 0;
  lobby.scores = {};
  lobby.players.forEach(pid => { lobby.scores[pid] = 0; });

  broadcast(lobbyId, { type: 'game_start', rounds: lobby.maxRounds });
  await nextRound(lobbyId);
}

async function nextRound(lobbyId) {
  const lobby = lobbies.get(lobbyId);
  if (!lobby) return;

  if (lobby.round >= lobby.maxRounds) {
    return endGame(lobbyId);
  }

  lobby.round++;
  info(`[${lobbyId}] Round ${lobby.round} - generating word...`);

  const word = await generateWordWithAI(lobby.difficulty);
  const hint = await generateHint(word, lobby.difficulty);
  lobby.currentWord = word;
  lobby.currentHint = hint;
  lobby.roundAnswered = false;
  lobby.roundStartTime = Date.now();

  broadcast(lobbyId, {
    type: 'new_round',
    round: lobby.round,
    maxRounds: lobby.maxRounds,
    hint,
    wordLength: word.length,
    timeLimit: 30
  });

  // Auto next round after 35s
  lobby.roundTimer = setTimeout(() => {
    if (lobbies.get(lobbyId)?.currentWord === word) {
      broadcast(lobbyId, { type: 'round_timeout', word, correctWord: word });
      setTimeout(() => nextRound(lobbyId), 3000);
    }
  }, 35000);
}

function checkAnswer(lobbyId, playerId, playerName, answer) {
  const lobby = lobbies.get(lobbyId);
  if (!lobby || lobby.status !== 'playing') return;

  const correct = answer.trim().toLowerCase() === lobby.currentWord.toLowerCase();
  const timeBonus = Math.max(0, 30 - Math.floor((Date.now() - lobby.roundStartTime) / 1000));
  const points = correct ? (10 + timeBonus) : 0;

  if (correct) {
    if (!lobby.scores[playerId]) lobby.scores[playerId] = 0;
    lobby.scores[playerId] += points;

    clearTimeout(lobby.roundTimer);

    broadcast(lobbyId, {
      type: 'correct_answer',
      playerId,
      playerName,
      word: lobby.currentWord,
      points,
      scores: getFormattedScores(lobby)
    });

    setTimeout(() => nextRound(lobbyId), 3000);
  } else {
    broadcast(lobbyId, {
      type: 'wrong_answer',
      playerId,
      playerName,
      attempt: answer
    });
  }
}

function getFormattedScores(lobby) {
  return lobby.players.map(pid => {
    let pname = 'Unknown';
    players.forEach((p) => { if (p.id === pid) pname = p.name; });
    return { id: pid, name: pname, score: lobby.scores[pid] || 0 };
  }).sort((a, b) => b.score - a.score);
}

function endGame(lobbyId) {
  const lobby = lobbies.get(lobbyId);
  if (!lobby) return;

  lobby.status = 'finished';
  const finalScores = getFormattedScores(lobby);

  // Persist scores to DB
  finalScores.forEach(({ name, score }) => {
    updateUserScore(name, score);
  });

  broadcast(lobbyId, {
    type: 'game_over',
    finalScores,
    leaderboard: getLeaderboard(10)
  });

  // Clean up lobby after 30s — clear all session data
  setTimeout(() => lobbies.delete(lobbyId), 30000);
}

function info(msg) { console.log(`[SpellDuel] ${msg}`); }

// ── Levenshtein distance ─────────────────────────────────
function levenshtein(a, b) {
  const m = a.length, n = b.length;
  const dp = Array.from({length: m+1}, (_, i) => Array.from({length: n+1}, (_, j) => i === 0 ? j : j === 0 ? i : 0));
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      dp[i][j] = a[i-1] === b[j-1] ? dp[i-1][j-1] : 1 + Math.min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1]);
  return dp[m][n];
}

function isClose(attempt, word) {
  const dist = levenshtein(attempt, word);
  // "Close" if within 2 edits and not identical
  return dist > 0 && dist <= 2;
}

// ── Translation Mode Helpers ─────────────────────────────
async function transNextRound(ws) {
  const p = players.get(ws);
  if (!p || !p.trans || ws.readyState !== 1) return;
  const t = p.trans;
  t.round++;
  const phrase = await generateTranslationChallenge(t.sourceLang, t.targetLang, t.minWords, t.maxWords);
  t.currentPhrase = phrase;
  t.roundStart = Date.now();
  ws.send(JSON.stringify({
    type: 'trans_round',
    round: t.round,
    maxRounds: t.rounds,
    phrase,
    sourceLang: t.sourceLang,
    targetLang: t.targetLang,
    lives: t.lives,
    score: t.score,
    streak: t.streak,
    timeLimit: 45
  }));
}

async function transEndGame(ws) {
  const p = players.get(ws);
  if (!p || !p.trans) return;
  const t = p.trans;
  const duration = Math.round((Date.now() - t.startTime) / 1000);

  // Persist score to DB
  updateUserScore(p.name, t.score);

  if (ws.readyState === 1) {
    ws.send(JSON.stringify({
      type: 'trans_over',
      score: t.score,
      correctCount: t.correctCount,
      totalRounds: t.round,
      bestStreak: t.bestStreak,
      lives: t.lives,
      duration,
      leaderboard: getLeaderboard(10)
    }));
  }
  // Clear session data
  p.trans = null;
}

// ── Solo Mode Helpers ────────────────────────────────────
async function soloNextRound(ws) {
  const p = players.get(ws);
  if (!p || !p.solo || ws.readyState !== 1) return;
  const s = p.solo;
  s.round++;
  const word = await generateWordWithAI(s.difficulty);
  const hint = await generateHint(word, s.difficulty);
  s.currentWord = word;
  s.currentHint = hint;
  s.roundStart = Date.now();
  ws.send(JSON.stringify({
    type: 'solo_round',
    round: s.round,
    maxRounds: s.rounds,
    hint,
    wordLength: word.length,
    lives: s.lives,
    score: s.score,
    streak: s.streak,
    timeLimit: 30
  }));
}

async function soloEndGame(ws) {
  const p = players.get(ws);
  if (!p || !p.solo) return;
  const s = p.solo;
  const duration = Math.round((Date.now() - s.startTime) / 1000);

  // Persist to DB
  updateUserScore(p.name, s.score);

  if (ws.readyState === 1) {
    ws.send(JSON.stringify({
      type: 'solo_over',
      score: s.score,
      correctCount: s.correctCount,
      totalRounds: s.round,
      bestStreak: s.bestStreak,
      lives: s.lives,
      duration,
      leaderboard: getLeaderboard(10)
    }));
  }
  // Clear all session AI data
  p.solo = null;
}


wss.on('connection', (ws) => {
  const player = { id: uuidv4(), name: 'Player', lobbyId: null };
  players.set(ws, player);

  ws.send(JSON.stringify({
    type: 'connected',
    playerId: player.id
  }));

  ws.on('message', async (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    const p = players.get(ws);
    if (!p) return;

    switch (msg.type) {
      case 'login': {
        const rawName = (msg.username || '').trim().substring(0, 20);
        if (!rawName) { ws.send(JSON.stringify({ type: 'login_error', msg: 'Username tidak boleh kosong' })); break; }
        const user = loginOrRegister(rawName);
        p.name = user.username;
        ws.send(JSON.stringify({
          type: 'login_ok',
          username: user.username,
          score: user.score,
          games_played: user.games_played,
          best_score: user.best_score,
          isNew: user.isNew,
          lobbies: getLobbyList(),
          leaderboard: getLeaderboard(10)
        }));
        break;
      }

      case 'set_name':
        p.name = (msg.name || 'Player').substring(0, 20);
        ws.send(JSON.stringify({ type: 'name_set', name: p.name }));
        break;

      case 'get_lobbies':
        ws.send(JSON.stringify({ type: 'lobby_list', lobbies: getLobbyList() }));
        break;

      case 'get_leaderboard':
        ws.send(JSON.stringify({ type: 'leaderboard', data: getLeaderboard(10) }));
        break;

      case 'create_lobby': {
        const lobby = createLobby(p.id, p.name, msg.settings || {});
        lobby.players.push(p.id);
        lobby.scores[p.id] = 0;
        p.lobbyId = lobby.id;
        ws.send(JSON.stringify({ type: 'lobby_created', lobby }));
        broadcastLobbyList();
        break;
      }

      case 'join_lobby': {
        const lobby = lobbies.get(msg.lobbyId);
        if (!lobby) { ws.send(JSON.stringify({ type: 'error', msg: 'Lobby not found' })); break; }
        if (lobby.status !== 'waiting') { ws.send(JSON.stringify({ type: 'error', msg: 'Game already started' })); break; }
        if (lobby.players.length >= lobby.maxPlayers) { ws.send(JSON.stringify({ type: 'error', msg: 'Lobby is full' })); break; }

        lobby.players.push(p.id);
        lobby.scores[p.id] = 0;
        p.lobbyId = lobby.id;

        const playerList = getFormattedScores(lobby);
        ws.send(JSON.stringify({ type: 'lobby_joined', lobby, players: playerList }));
        broadcast(lobby.id, { type: 'player_joined', playerName: p.name, players: playerList }, ws);
        broadcastLobbyList();
        break;
      }

      case 'leave_lobby': {
        const lobby = lobbies.get(p.lobbyId);
        if (!lobby) break;
        lobby.players = lobby.players.filter(id => id !== p.id);
        delete lobby.scores[p.id];
        broadcast(lobby.id, { type: 'player_left', playerName: p.name, players: getFormattedScores(lobby) });
        p.lobbyId = null;
        ws.send(JSON.stringify({ type: 'left_lobby' }));
        if (lobby.players.length === 0) lobbies.delete(lobby.id);
        broadcastLobbyList();
        break;
      }

      case 'start_game': {
        const lobby = lobbies.get(p.lobbyId);
        if (!lobby) break;
        if (lobby.hostId !== p.id) { ws.send(JSON.stringify({ type: 'error', msg: 'Only host can start' })); break; }
        await startGame(lobby.id);
        break;
      }

      case 'submit_answer': {
        if (!p.lobbyId) break;
        checkAnswer(p.lobbyId, p.id, p.name, msg.answer || '');
        break;
      }

      // ── SOLO MODE ────────────────────────────────────────
      case 'solo_start': {
        p.solo = {
          difficulty: msg.difficulty || 'medium',
          rounds: msg.rounds || 5,
          round: 0,
          score: 0,
          lives: 3,
          streak: 0,
          bestStreak: 0,
          correctCount: 0,
          startTime: Date.now()
        };
        ws.send(JSON.stringify({ type: 'solo_started', settings: p.solo }));
        await soloNextRound(ws);
        break;
      }

      case 'solo_answer': {
        if (!p.solo) break;
        const s = p.solo;
        const attempt = (msg.answer || '').trim().toLowerCase();
        const correct = attempt === s.currentWord.toLowerCase();
        const close = !correct && isClose(attempt, s.currentWord.toLowerCase());
        const timeBonus = Math.max(0, 30 - Math.floor((Date.now() - s.roundStart) / 1000));
        if (correct) {
          s.streak++;
          s.bestStreak = Math.max(s.bestStreak, s.streak);
          s.correctCount++;
          const streakBonus = s.streak >= 3 ? Math.floor(s.streak * 2) : 0;
          const pts = 10 + timeBonus + streakBonus;
          s.score += pts;
          ws.send(JSON.stringify({
            type: 'solo_correct',
            word: s.currentWord,
            pts,
            timeBonus,
            streakBonus,
            streak: s.streak,
            score: s.score,
            lives: s.lives
          }));
          if (s.round >= s.rounds) {
            await soloEndGame(ws);
          } else {
            setTimeout(() => { if (players.get(ws)?.solo) soloNextRound(ws); }, 2000);
          }
        } else if (close) {
          // Mendekati — tidak kurangi nyawa, beri kesempatan coba lagi
          ws.send(JSON.stringify({
            type: 'solo_close',
            attempt: msg.answer,
            lives: s.lives,
            score: s.score
          }));
        } else {
          s.streak = 0;
          s.lives--;
          ws.send(JSON.stringify({
            type: 'solo_wrong',
            attempt: msg.answer,
            word: s.currentWord,
            lives: s.lives,
            score: s.score
          }));
          if (s.lives <= 0) {
            await soloEndGame(ws);
          }
          // else: player can retry same word
        }
        break;
      }

      case 'solo_skip': {
        if (!p.solo) break;
        p.solo.lives = Math.max(0, p.solo.lives - 1);
        p.solo.streak = 0;
        ws.send(JSON.stringify({ type: 'solo_skipped', word: p.solo.currentWord, lives: p.solo.lives }));
        if (p.solo.lives <= 0) {
          await soloEndGame(ws);
        } else if (p.solo.round >= p.solo.rounds) {
          await soloEndGame(ws);
        } else {
          setTimeout(() => { if (players.get(ws)?.solo) soloNextRound(ws); }, 1500);
        }
        break;
      }

      case 'solo_quit': {
        if (p.solo) await soloEndGame(ws);
        break;
      }

      // ── TRANSLATION MODE ─────────────────────────────────
      case 'trans_start': {
        const minW = Math.max(1, Math.min(parseInt(msg.minWords) || 3, 20));
        const maxW = Math.max(minW, Math.min(parseInt(msg.maxWords) || 6, 30));
        p.trans = {
          sourceLang: (msg.sourceLang || 'English').substring(0, 30),
          targetLang: (msg.targetLang || 'Indonesian').substring(0, 30),
          minWords: minW,
          maxWords: maxW,
          rounds: parseInt(msg.rounds) || 5,
          round: 0,
          score: 0,
          lives: 3,
          streak: 0,
          bestStreak: 0,
          correctCount: 0,
          startTime: Date.now(),
          currentPhrase: null,
          roundStart: null
        };
        ws.send(JSON.stringify({ type: 'trans_started', settings: { ...p.trans, currentPhrase: undefined } }));
        await transNextRound(ws);
        break;
      }

      case 'trans_answer': {
        if (!p.trans) break;
        const t = p.trans;
        if (!t.currentPhrase) break;
        const answer = (msg.answer || '').trim();
        if (!answer) break;

        ws.send(JSON.stringify({ type: 'trans_checking' }));
        const verdict = await checkTranslation(t.currentPhrase, answer, t.sourceLang, t.targetLang);
        const timeBonus = Math.max(0, 45 - Math.floor((Date.now() - t.roundStart) / 1000));

        if (verdict === 'CORRECT') {
          t.streak++;
          t.bestStreak = Math.max(t.bestStreak, t.streak);
          t.correctCount++;
          const streakBonus = t.streak >= 3 ? Math.floor(t.streak * 2) : 0;
          const pts = 15 + timeBonus + streakBonus;
          t.score += pts;
          t.currentPhrase = null;
          ws.send(JSON.stringify({ type: 'trans_correct', pts, timeBonus, streakBonus, streak: t.streak, score: t.score, lives: t.lives }));
          if (t.round >= t.rounds) {
            await transEndGame(ws);
          } else {
            setTimeout(() => { if (players.get(ws)?.trans) transNextRound(ws); }, 2000);
          }
        } else if (verdict === 'CLOSE') {
          ws.send(JSON.stringify({ type: 'trans_close', attempt: answer, lives: t.lives, score: t.score }));
        } else {
          t.streak = 0;
          t.lives--;
          t.currentPhrase = null;
          ws.send(JSON.stringify({ type: 'trans_wrong', attempt: answer, lives: t.lives, score: t.score }));
          if (t.lives <= 0) {
            await transEndGame(ws);
          } else {
            setTimeout(() => { if (players.get(ws)?.trans) transNextRound(ws); }, 2000);
          }
        }
        break;
      }

      case 'trans_skip': {
        if (!p.trans) break;
        p.trans.lives = Math.max(0, p.trans.lives - 1);
        p.trans.streak = 0;
        const skippedPhrase = p.trans.currentPhrase;
        p.trans.currentPhrase = null;
        ws.send(JSON.stringify({ type: 'trans_skipped', phrase: skippedPhrase, lives: p.trans.lives }));
        if (p.trans.lives <= 0 || p.trans.round >= p.trans.rounds) {
          await transEndGame(ws);
        } else {
          setTimeout(() => { if (players.get(ws)?.trans) transNextRound(ws); }, 1500);
        }
        break;
      }

      case 'trans_quit': {
        if (p.trans) await transEndGame(ws);
        break;
      }
    }
  });

  ws.on('close', () => {
    const p = players.get(ws);
    if (p?.lobbyId) {
      const lobby = lobbies.get(p.lobbyId);
      if (lobby) {
        lobby.players = lobby.players.filter(id => id !== p.id);
        broadcast(lobby.id, { type: 'player_left', playerName: p.name, players: getFormattedScores(lobby) });
        if (lobby.players.length === 0) lobbies.delete(lobby.id);
      }
    }
    players.delete(ws);
    broadcastLobbyList();
  });
});

// ── REST API ─────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'spellduel' }));
app.get('/api/leaderboard', (req, res) => res.json(getLeaderboard(20)));
app.get('/api/lobbies', (req, res) => res.json(getLobbyList()));

const PORT = process.env.PORT || 3001;
server.listen(PORT, () => {
  info(`🚀 SpellDuel backend running on port ${PORT}`);
  info(`🔌 WebSocket ready at ws://localhost:${PORT}/ws`);
});
SERVEREOF

  log "Backend created"
}

# ============================================================
# STEP 5: CREATE FRONTEND
# ============================================================
create_frontend() {
  section "Building Frontend (Single HTML App)"

  mkdir -p "$WWW_DIR"

  cat > "$WWW_DIR/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>SpellDuel — AI Spelling Battle</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Syne:wght@400;600;700;800&family=Space+Mono:wght@400;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0a0a0f;
      --surface: #12121a;
      --surface2: #1a1a26;
      --border: #2a2a3f;
      --accent: #7c3aed;
      --accent2: #06b6d4;
      --accent3: #f59e0b;
      --success: #10b981;
      --danger: #ef4444;
      --text: #e8e8f0;
      --muted: #6b6b8a;
      --glow: 0 0 30px rgba(124,58,237,0.3);
    }

    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: 'Syne', sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      overflow-x: hidden;
    }

    /* BG Grid */
    body::before {
      content: '';
      position: fixed;
      inset: 0;
      background-image:
        linear-gradient(rgba(124,58,237,0.03) 1px, transparent 1px),
        linear-gradient(90deg, rgba(124,58,237,0.03) 1px, transparent 1px);
      background-size: 50px 50px;
      pointer-events: none;
      z-index: 0;
    }

    #app {
      position: relative;
      z-index: 1;
      max-width: 900px;
      margin: 0 auto;
      padding: 20px;
      min-height: 100vh;
    }

    /* ── Header ── */
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 20px 0 32px;
      border-bottom: 1px solid var(--border);
      margin-bottom: 32px;
    }
    .logo {
      font-size: 1.6rem;
      font-weight: 800;
      letter-spacing: -0.02em;
    }
    .logo span { color: var(--accent); }
    .logo em { color: var(--accent2); font-style: normal; }

    .player-badge {
      display: flex;
      align-items: center;
      gap: 10px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 100px;
      padding: 8px 16px;
      font-size: 0.85rem;
      font-weight: 600;
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--success); box-shadow: 0 0 8px var(--success); }

    /* ── Screens ── */
    .screen { display: none; animation: fadeIn 0.3s ease; }
    .screen.active { display: block; }
    @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }

    /* ── Buttons ── */
    .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      padding: 12px 24px;
      border-radius: 10px;
      font-family: 'Syne', sans-serif;
      font-size: 0.9rem;
      font-weight: 700;
      cursor: pointer;
      border: none;
      transition: all 0.15s ease;
      letter-spacing: 0.02em;
    }
    .btn-primary {
      background: var(--accent);
      color: white;
      box-shadow: 0 4px 20px rgba(124,58,237,0.4);
    }
    .btn-primary:hover { background: #6d28d9; transform: translateY(-1px); box-shadow: 0 6px 25px rgba(124,58,237,0.5); }
    .btn-secondary {
      background: var(--surface2);
      color: var(--text);
      border: 1px solid var(--border);
    }
    .btn-secondary:hover { background: var(--surface); border-color: var(--accent); }
    .btn-cyan {
      background: var(--accent2);
      color: #0a0a0f;
      box-shadow: 0 4px 20px rgba(6,182,212,0.3);
    }
    .btn-cyan:hover { opacity: 0.9; transform: translateY(-1px); }
    .btn-danger { background: var(--danger); color: white; }
    .btn-sm { padding: 8px 16px; font-size: 0.8rem; }
    .btn:disabled { opacity: 0.4; cursor: not-allowed; transform: none !important; }
    .btn-full { width: 100%; }

    /* ── Cards ── */
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 24px;
    }
    .card-title {
      font-size: 1.1rem;
      font-weight: 700;
      margin-bottom: 16px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .card-title .badge {
      font-size: 0.7rem;
      background: var(--accent);
      color: white;
      padding: 2px 8px;
      border-radius: 100px;
    }

    /* ── Input ── */
    .input {
      width: 100%;
      background: var(--surface2);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 12px 16px;
      color: var(--text);
      font-family: 'Syne', sans-serif;
      font-size: 0.95rem;
      outline: none;
      transition: border-color 0.2s;
    }
    .input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(124,58,237,0.15); }
    .input::placeholder { color: var(--muted); }

    select.input option { background: var(--surface2); }

    .input-label {
      font-size: 0.78rem;
      font-weight: 700;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: 0.08em;
      margin-bottom: 6px;
      display: block;
    }
    .input-group { margin-bottom: 16px; }

    /* ── SETUP SCREEN ── */
    .setup-hero {
      text-align: center;
      padding: 40px 0 48px;
    }
    .setup-hero h1 {
      font-size: 3.5rem;
      font-weight: 800;
      line-height: 1.1;
      letter-spacing: -0.03em;
      margin-bottom: 12px;
    }
    .setup-hero h1 .line2 { color: var(--accent); }
    .setup-hero p {
      color: var(--muted);
      font-size: 1rem;
      max-width: 400px;
      margin: 0 auto 32px;
    }
    .setup-name-form {
      max-width: 400px;
      margin: 0 auto;
      display: flex;
      gap: 12px;
    }

    /* ── LOBBY SCREEN ── */
    .lobby-grid { display: grid; grid-template-columns: 1fr 340px; gap: 24px; }
    @media(max-width:700px){ .lobby-grid { grid-template-columns: 1fr; } }

    .lobby-list { display: flex; flex-direction: column; gap: 10px; }
    .lobby-item {
      background: var(--surface2);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 16px 20px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      transition: border-color 0.2s, transform 0.15s;
      cursor: pointer;
    }
    .lobby-item:hover { border-color: var(--accent); transform: translateX(3px); }
    .lobby-item-name { font-weight: 700; font-size: 0.95rem; margin-bottom: 4px; }
    .lobby-item-meta { font-size: 0.78rem; color: var(--muted); display: flex; gap: 12px; }
    .diff-badge {
      font-size: 0.7rem;
      font-weight: 700;
      padding: 3px 10px;
      border-radius: 100px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }
    .diff-easy { background: rgba(16,185,129,0.15); color: var(--success); }
    .diff-medium { background: rgba(245,158,11,0.15); color: var(--accent3); }
    .diff-hard { background: rgba(239,68,68,0.15); color: var(--danger); }

    .empty-state {
      text-align: center;
      padding: 60px 20px;
      color: var(--muted);
    }
    .empty-state .icon { font-size: 3rem; margin-bottom: 12px; }

    /* Create Lobby Form */
    .create-form { display: flex; flex-direction: column; gap: 4px; }

    /* ── WAITING ROOM ── */
    .waiting-header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      margin-bottom: 28px;
      flex-wrap: wrap;
      gap: 12px;
    }
    .waiting-title { font-size: 1.6rem; font-weight: 800; }
    .waiting-subtitle { color: var(--muted); font-size: 0.85rem; margin-top: 4px; }

    .players-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
      gap: 12px;
      margin-bottom: 24px;
    }
    .player-card {
      background: var(--surface2);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 20px 16px;
      text-align: center;
    }
    .player-card .avatar {
      width: 48px;
      height: 48px;
      border-radius: 50%;
      background: linear-gradient(135deg, var(--accent), var(--accent2));
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 1.3rem;
      font-weight: 800;
      margin: 0 auto 10px;
    }
    .player-card .pname { font-weight: 700; font-size: 0.85rem; }
    .player-card .host-tag { font-size: 0.7rem; color: var(--accent3); margin-top: 4px; }

    /* ── GAME SCREEN ── */
    .game-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 28px;
    }
    .round-info { font-size: 0.85rem; color: var(--muted); font-weight: 700; text-transform: uppercase; letter-spacing: 0.1em; }
    .round-num { font-size: 1.4rem; font-weight: 800; color: var(--text); }

    .timer-ring {
      width: 64px;
      height: 64px;
      position: relative;
    }
    .timer-ring svg { transform: rotate(-90deg); }
    .timer-ring .track { fill: none; stroke: var(--border); stroke-width: 4; }
    .timer-ring .progress { fill: none; stroke: var(--accent2); stroke-width: 4; stroke-linecap: round; transition: stroke-dashoffset 1s linear, stroke 0.5s; }
    .timer-ring .label {
      position: absolute;
      inset: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      font-family: 'Space Mono', monospace;
      font-size: 1rem;
      font-weight: 700;
    }

    .hint-box {
      background: linear-gradient(135deg, rgba(124,58,237,0.1), rgba(6,182,212,0.05));
      border: 1px solid rgba(124,58,237,0.3);
      border-radius: 16px;
      padding: 28px 32px;
      margin-bottom: 24px;
      text-align: center;
    }
    .hint-label { font-size: 0.7rem; font-weight: 700; color: var(--accent2); text-transform: uppercase; letter-spacing: 0.12em; margin-bottom: 12px; }
    .hint-text {
      font-size: 1.3rem;
      font-weight: 600;
      line-height: 1.5;
      margin-bottom: 16px;
    }
    .word-length {
      font-family: 'Space Mono', monospace;
      font-size: 0.85rem;
      color: var(--muted);
    }
    .word-blanks {
      display: flex;
      justify-content: center;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    .blank {
      width: 22px;
      height: 3px;
      background: var(--border);
      border-radius: 2px;
      transition: background 0.3s;
    }
    .blank.filled { background: var(--accent); }

    .tts-btn {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      background: rgba(6,182,212,0.1);
      border: 1px solid rgba(6,182,212,0.3);
      color: var(--accent2);
      border-radius: 100px;
      padding: 8px 16px;
      font-size: 0.8rem;
      font-weight: 700;
      cursor: pointer;
      transition: all 0.2s;
      font-family: 'Syne', sans-serif;
    }
    .tts-btn:hover { background: rgba(6,182,212,0.2); }
    .tts-btn.speaking { animation: pulse 1s ease infinite; }
    @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.5; } }

    .answer-area {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 16px;
    }

    .spell-input {
      width: 100%;
      max-width: 400px;
      background: var(--surface2);
      border: 2px solid var(--border);
      border-radius: 14px;
      padding: 18px 24px;
      color: var(--text);
      font-family: 'Space Mono', monospace;
      font-size: 1.4rem;
      text-align: center;
      font-weight: 700;
      letter-spacing: 0.2em;
      text-transform: lowercase;
      outline: none;
      transition: all 0.2s;
    }
    .spell-input:focus { border-color: var(--accent); box-shadow: var(--glow); }
    .spell-input.correct { border-color: var(--success); box-shadow: 0 0 20px rgba(16,185,129,0.3); animation: correctFlash 0.4s ease; }
    .spell-input.wrong { border-color: var(--danger); animation: shake 0.3s ease; }
    @keyframes correctFlash { 0%,100% { background: var(--surface2); } 50% { background: rgba(16,185,129,0.15); } }
    @keyframes shake { 0%,100% { transform: translateX(0); } 25% { transform: translateX(-8px); } 75% { transform: translateX(8px); } }

    .scoreboard {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 14px;
      overflow: hidden;
      margin-top: 24px;
    }
    .scoreboard-title {
      padding: 12px 20px;
      background: var(--surface2);
      font-size: 0.75rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      color: var(--muted);
    }
    .score-row {
      display: flex;
      align-items: center;
      padding: 10px 20px;
      border-top: 1px solid var(--border);
      font-size: 0.9rem;
      transition: background 0.2s;
    }
    .score-row:hover { background: var(--surface2); }
    .score-rank { width: 28px; font-weight: 800; color: var(--muted); font-size: 0.8rem; }
    .score-rank.gold { color: #fbbf24; }
    .score-rank.silver { color: #94a3b8; }
    .score-rank.bronze { color: #cd7c3a; }
    .score-name { flex: 1; font-weight: 600; }
    .score-name.me { color: var(--accent2); }
    .score-pts {
      font-family: 'Space Mono', monospace;
      font-weight: 700;
      font-size: 0.85rem;
    }

    /* ── GAME OVER ── */
    .game-over-wrap {
      text-align: center;
      padding: 40px 0;
    }
    .game-over-title {
      font-size: 2.5rem;
      font-weight: 800;
      letter-spacing: -0.03em;
      margin-bottom: 8px;
    }
    .game-over-sub { color: var(--muted); margin-bottom: 32px; }
    .winner-spotlight {
      background: linear-gradient(135deg, rgba(245,158,11,0.12), rgba(124,58,237,0.08));
      border: 1px solid rgba(245,158,11,0.25);
      border-radius: 20px;
      padding: 32px;
      margin-bottom: 32px;
      display: inline-block;
      min-width: 240px;
    }
    .winner-trophy { font-size: 3rem; margin-bottom: 8px; }
    .winner-name { font-size: 1.4rem; font-weight: 800; }
    .winner-score { color: var(--accent3); font-family: 'Space Mono', monospace; font-size: 1.1rem; margin-top: 4px; }

    /* ── LEADERBOARD ── */
    .lb-row {
      display: grid;
      grid-template-columns: 36px 1fr 80px 80px;
      align-items: center;
      padding: 12px 20px;
      border-top: 1px solid var(--border);
      font-size: 0.88rem;
    }
    .lb-header {
      display: grid;
      grid-template-columns: 36px 1fr 80px 80px;
      padding: 10px 20px;
      font-size: 0.72rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--muted);
    }

    /* ── Notifications ── */
    #notif {
      position: fixed;
      bottom: 24px;
      right: 24px;
      z-index: 999;
      display: flex;
      flex-direction: column;
      gap: 8px;
      pointer-events: none;
    }
    .notif-item {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 12px 18px;
      font-size: 0.85rem;
      font-weight: 600;
      animation: notifIn 0.3s ease;
      pointer-events: auto;
      max-width: 280px;
    }
    .notif-item.success { border-color: var(--success); color: var(--success); }
    .notif-item.error { border-color: var(--danger); color: var(--danger); }
    .notif-item.info { border-color: var(--accent2); color: var(--accent2); }
    @keyframes notifIn { from { opacity: 0; transform: translateX(20px); } to { opacity: 1; transform: translateX(0); } }

    /* ── Connection status ── */
    .conn-status {
      position: fixed;
      top: 16px;
      right: 16px;
      font-size: 0.72rem;
      padding: 6px 12px;
      border-radius: 100px;
      font-weight: 700;
      z-index: 100;
    }
    .conn-ok { background: rgba(16,185,129,0.15); color: var(--success); border: 1px solid rgba(16,185,129,0.3); }
    .conn-err { background: rgba(239,68,68,0.15); color: var(--danger); border: 1px solid rgba(239,68,68,0.3); }

    /* ── Tabs ── */
    .tabs { display: flex; gap: 4px; margin-bottom: 20px; }
    .tab {
      padding: 8px 18px;
      border-radius: 8px;
      font-size: 0.85rem;
      font-weight: 700;
      cursor: pointer;
      color: var(--muted);
      transition: all 0.2s;
      border: none;
      background: none;
      font-family: 'Syne', sans-serif;
    }
    .tab.active { background: var(--surface2); color: var(--text); border: 1px solid var(--border); }
    .tab:hover:not(.active) { color: var(--text); }

    /* Events log */
    .events-log {
      height: 120px;
      overflow-y: auto;
      background: var(--surface2);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 10px 14px;
      font-size: 0.8rem;
      color: var(--muted);
      line-height: 1.8;
      margin-top: 16px;
      font-family: 'Space Mono', monospace;
    }
    .events-log .ev-correct { color: var(--success); }
    .events-log .ev-wrong { color: var(--danger); }
    .events-log .ev-info { color: var(--accent2); }

    .gap-row { display: flex; gap: 12px; }
    .gap-row > * { flex: 1; }

    @media(max-width:480px) {
      .setup-hero h1 { font-size: 2.2rem; }
      .setup-name-form { flex-direction: column; }
      .hint-text { font-size: 1rem; }
      .spell-input { font-size: 1.1rem; }
    }

    /* ── SOLO MODE ── */
    .solo-stats-bar {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 10px;
      margin-bottom: 24px;
    }
    @media(max-width:500px){ .solo-stats-bar { grid-template-columns: repeat(2,1fr); } }
    .solo-stat {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 14px 16px;
      text-align: center;
    }
    .solo-stat-val {
      font-family: 'Space Mono', monospace;
      font-size: 1.5rem;
      font-weight: 700;
      line-height: 1;
      margin-bottom: 4px;
    }
    .solo-stat-label { font-size: 0.7rem; font-weight: 700; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; }
    .lives-display { display: flex; justify-content: center; gap: 6px; font-size: 1.3rem; }

    .streak-fire {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      background: rgba(245,158,11,0.12);
      border: 1px solid rgba(245,158,11,0.3);
      color: var(--accent3);
      border-radius: 100px;
      padding: 6px 14px;
      font-size: 0.85rem;
      font-weight: 700;
      transition: all 0.3s;
    }
    .streak-fire.hot { animation: fireGlow 0.5s ease; }
    @keyframes fireGlow { 0%,100%{ box-shadow:none; } 50%{ box-shadow:0 0 20px rgba(245,158,11,0.5); } }

    .solo-result-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 12px;
      margin-bottom: 24px;
    }
    @media(max-width:480px){ .solo-result-grid { grid-template-columns: 1fr; } }
    .result-stat {
      background: var(--surface2);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 20px;
      text-align: center;
    }
    .result-stat-val {
      font-family: 'Space Mono', monospace;
      font-size: 2rem;
      font-weight: 700;
      margin-bottom: 4px;
    }
    .result-stat-val.gold { color: #fbbf24; }
    .result-stat-val.cyan { color: var(--accent2); }
    .result-stat-val.green { color: var(--success); }
    .result-stat-val.purple { color: var(--accent); }
    .result-stat-label { font-size: 0.75rem; color: var(--muted); font-weight: 700; text-transform: uppercase; letter-spacing: 0.07em; }

    .solo-setup-card {
      max-width: 420px;
      margin: 0 auto;
    }
    .mode-cards {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
      margin-bottom: 24px;
    }
    @media(max-width:480px){ .mode-cards { grid-template-columns:1fr; } }
    .mode-card {
      background: var(--surface2);
      border: 2px solid var(--border);
      border-radius: 14px;
      padding: 20px 16px;
      cursor: pointer;
      transition: all 0.2s;
      text-align: center;
    }
    .mode-card:hover { border-color: var(--accent); transform: translateY(-2px); }
    .mode-card.selected { border-color: var(--accent); background: rgba(124,58,237,0.08); }
    .mode-card-icon { font-size: 2rem; margin-bottom: 8px; }
    .mode-card-name { font-weight: 700; font-size: 0.9rem; margin-bottom: 4px; }
    .mode-card-desc { font-size: 0.75rem; color: var(--muted); }

    /* ── DESKTOP LAYOUT ── */
    @media(min-width: 1024px) {
      body { font-size: 17px; }
      #app {
        max-width: 1100px;
        padding: 32px 48px;
      }
      .header { padding: 28px 0 40px; margin-bottom: 40px; }
      .logo { font-size: 2rem; }
      .player-badge { font-size: 1rem; padding: 10px 22px; }
      .setup-hero { padding: 60px 0 72px; }
      .setup-hero h1 { font-size: 5rem; }
      .setup-hero p { font-size: 1.15rem; max-width: 520px; }
      .setup-name-form { max-width: 500px; }
      .setup-name-form .input { font-size: 1.1rem; padding: 16px 20px; }
      .btn { padding: 14px 32px; font-size: 1rem; }
      .btn-sm { padding: 10px 20px; font-size: 0.88rem; }
      .card { padding: 32px; border-radius: 20px; }
      .card-title { font-size: 1.25rem; margin-bottom: 20px; }
      .tabs { gap: 8px; margin-bottom: 28px; }
      .tab { padding: 10px 24px; font-size: 0.95rem; border-radius: 10px; }
      .input { padding: 14px 20px; font-size: 1rem; border-radius: 12px; }
      .input-label { font-size: 0.82rem; }
      .lobby-item { padding: 20px 28px; border-radius: 16px; }
      .lobby-item-name { font-size: 1.05rem; margin-bottom: 6px; }
      .lobby-item-meta { font-size: 0.85rem; gap: 16px; }
      .diff-badge { font-size: 0.78rem; padding: 4px 14px; }
      .hint-box { padding: 40px 48px; border-radius: 20px; margin-bottom: 32px; }
      .hint-label { font-size: 0.8rem; margin-bottom: 16px; }
      .hint-text { font-size: 1.6rem; margin-bottom: 20px; }
      .word-length { font-size: 0.95rem; }
      .blank { width: 28px; height: 4px; }
      .tts-btn { padding: 10px 22px; font-size: 0.9rem; }
      .spell-input { max-width: 520px; font-size: 1.8rem; padding: 22px 30px; border-radius: 18px; }
      .answer-area { gap: 20px; }
      .scoreboard { border-radius: 18px; margin-top: 32px; }
      .scoreboard-title { padding: 16px 28px; font-size: 0.8rem; }
      .score-row { padding: 14px 28px; font-size: 1rem; }
      .score-rank { width: 36px; font-size: 0.9rem; }
      .score-pts { font-size: 0.95rem; }
      .events-log { height: 150px; font-size: 0.88rem; padding: 14px 20px; margin-top: 24px; border-radius: 14px; }
      .game-header { margin-bottom: 36px; }
      .round-info { font-size: 0.95rem; }
      .round-num { font-size: 1.8rem; }
      .timer-ring { width: 80px; height: 80px; }
      .timer-ring svg { width: 80px; height: 80px; }
      .timer-ring .label { font-size: 1.2rem; }
      .waiting-title { font-size: 2rem; }
      .waiting-subtitle { font-size: 0.95rem; }
      .player-card { padding: 28px 20px; border-radius: 16px; }
      .player-card .avatar { width: 60px; height: 60px; font-size: 1.6rem; }
      .player-card .pname { font-size: 1rem; }
      .players-grid { grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 16px; margin-bottom: 32px; }
      .game-over-title { font-size: 3.2rem; }
      .winner-spotlight { padding: 44px; min-width: 300px; }
      .winner-trophy { font-size: 4rem; }
      .winner-name { font-size: 1.8rem; }
      .winner-score { font-size: 1.3rem; }
      .lb-row { padding: 16px 28px; font-size: 0.98rem; }
      .lb-header { padding: 12px 28px; font-size: 0.78rem; }
      .solo-stats-bar { gap: 16px; margin-bottom: 32px; }
      .solo-stat { padding: 20px 24px; border-radius: 16px; }
      .solo-stat-val { font-size: 2rem; }
      .solo-stat-label { font-size: 0.78rem; }
      .streak-fire { font-size: 0.95rem; padding: 10px 20px; }
      .result-stat { padding: 28px; border-radius: 18px; }
      .result-stat-val { font-size: 2.6rem; }
      .solo-result-grid { gap: 16px; margin-bottom: 32px; }
      .notif-item { font-size: 0.95rem; padding: 14px 22px; max-width: 340px; }
    }

    @media(min-width: 1400px) {
      #app { max-width: 1260px; }
      .setup-hero h1 { font-size: 6rem; }
      .hint-text { font-size: 1.9rem; }
      .spell-input { font-size: 2rem; max-width: 580px; }
    }

    /* ── FLOATING NAVBAR (desktop) ── */
    #floatingNav {
      display: none; /* hidden on mobile, shown via JS when logged in */
      position: fixed;
      top: 20px;
      left: 50%;
      transform: translateX(-50%);
      z-index: 500;
      background: rgba(18,18,26,0.85);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border: 1px solid var(--border);
      border-radius: 100px;
      padding: 8px 16px;
      display: flex;
      align-items: center;
      gap: 4px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.4), 0 0 0 1px rgba(124,58,237,0.1);
    }
    #floatingNav .nav-logo {
      font-size: 1rem;
      font-weight: 800;
      letter-spacing: -0.02em;
      padding-right: 12px;
      border-right: 1px solid var(--border);
      margin-right: 8px;
      white-space: nowrap;
    }
    #floatingNav .nav-logo span { color: var(--accent); }
    #floatingNav .nav-logo em { color: var(--accent2); font-style: normal; }
    .nav-btn {
      background: none;
      border: none;
      color: var(--muted);
      font-family: 'Syne', sans-serif;
      font-size: 0.82rem;
      font-weight: 700;
      padding: 7px 14px;
      border-radius: 100px;
      cursor: pointer;
      transition: all 0.15s;
      white-space: nowrap;
    }
    .nav-btn:hover { color: var(--text); background: rgba(255,255,255,0.06); }
    .nav-btn.active { color: var(--text); background: var(--surface2); border: 1px solid var(--border); }
    .nav-btn.nav-hamburger {
      display: none;
      font-size: 1.1rem;
      padding: 7px 12px;
    }

    /* Mobile: hide floating nav, show hamburger in header */
    @media(max-width: 767px) {
      #floatingNav { display: none !important; }
      .mobile-hamburger-btn {
        display: flex !important;
      }
    }
    @media(min-width: 768px) {
      .mobile-hamburger-btn { display: none !important; }
      #floatingNav { display: flex !important; }
      /* Add top padding so content isn't behind floating nav */
      #app { padding-top: 72px; }
    }

    /* ── MOBILE HAMBURGER in header ── */
    .mobile-hamburger-btn {
      display: none;
      background: var(--surface);
      border: 1px solid var(--border);
      color: var(--text);
      border-radius: 10px;
      padding: 8px 13px;
      font-size: 1.2rem;
      cursor: pointer;
      transition: background 0.2s;
    }
    .mobile-hamburger-btn:hover { background: var(--surface2); }

    /* ── MOBILE SIDEBAR (right to left) ── */
    #mobileSidebar {
      position: fixed;
      top: 0;
      right: -320px;
      width: 280px;
      max-width: 85vw;
      height: 100vh;
      background: var(--surface);
      border-left: 1px solid var(--border);
      z-index: 1000;
      transition: right 0.3s cubic-bezier(0.4,0,0.2,1);
      display: flex;
      flex-direction: column;
      padding: 24px 20px;
      gap: 6px;
      box-shadow: -8px 0 32px rgba(0,0,0,0.5);
    }
    #mobileSidebar.open { right: 0; }
    .sidebar-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 20px;
      padding-bottom: 16px;
      border-bottom: 1px solid var(--border);
    }
    .sidebar-logo { font-size: 1.1rem; font-weight: 800; }
    .sidebar-logo span { color: var(--accent); }
    .sidebar-logo em { color: var(--accent2); font-style: normal; }
    .sidebar-close {
      background: none;
      border: none;
      color: var(--muted);
      font-size: 1.3rem;
      cursor: pointer;
      padding: 4px 8px;
      border-radius: 6px;
      transition: background 0.15s, color 0.15s;
    }
    .sidebar-close:hover { background: var(--surface2); color: var(--text); }
    .sidebar-nav-btn {
      background: none;
      border: none;
      color: var(--muted);
      font-family: 'Syne', sans-serif;
      font-size: 0.95rem;
      font-weight: 700;
      padding: 13px 16px;
      border-radius: 10px;
      cursor: pointer;
      transition: all 0.15s;
      text-align: left;
      width: 100%;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .sidebar-nav-btn:hover { color: var(--text); background: var(--surface2); }
    .sidebar-nav-btn.active { color: var(--text); background: rgba(124,58,237,0.12); border: 1px solid rgba(124,58,237,0.25); }

    #sidebarOverlay {
      display: none;
      position: fixed;
      inset: 0;
      background: rgba(0,0,0,0.5);
      z-index: 999;
      backdrop-filter: blur(2px);
    }
    #sidebarOverlay.visible { display: block; }
  </style>
</head>
<body>

<!-- FLOATING NAVBAR (desktop) -->
<nav id="floatingNav" style="display:none">
  <div class="nav-logo">Spell<span>Duel</span> <em>AI</em></div>
  <button class="nav-btn" id="nav-browse" onclick="navGoTo('browse')">🏛️ Browse</button>
  <button class="nav-btn" id="nav-create" onclick="navGoTo('create')">➕ Create</button>
  <button class="nav-btn" id="nav-solo" onclick="navGoTo('solo')">🎯 Solo</button>
  <button class="nav-btn" id="nav-trans" onclick="navGoTo('trans')">🌐 Translation</button>
  <button class="nav-btn" id="nav-lb" onclick="navGoTo('lb')">🏆 Leaderboard</button>
</nav>

<!-- MOBILE SIDEBAR OVERLAY -->
<div id="sidebarOverlay" onclick="closeSidebar()"></div>

<!-- MOBILE SIDEBAR -->
<aside id="mobileSidebar">
  <div class="sidebar-header">
    <div class="sidebar-logo">Spell<span>Duel</span> <em>AI</em></div>
    <button class="sidebar-close" onclick="closeSidebar()">✕</button>
  </div>
  <button class="sidebar-nav-btn" id="snav-browse" onclick="navGoTo('browse');closeSidebar()">🏛️ Browse Lobbies</button>
  <button class="sidebar-nav-btn" id="snav-create" onclick="navGoTo('create');closeSidebar()">➕ Create Room</button>
  <button class="sidebar-nav-btn" id="snav-solo" onclick="navGoTo('solo');closeSidebar()">🎯 Solo Practice</button>
  <button class="sidebar-nav-btn" id="snav-trans" onclick="navGoTo('trans');closeSidebar()">🌐 Translation</button>
  <button class="sidebar-nav-btn" id="snav-lb" onclick="navGoTo('lb');closeSidebar()">🏆 Leaderboard</button>
  <div style="margin-top:auto;padding-top:20px;border-top:1px solid var(--border)">
    <div id="sidebarPlayerName" style="color:var(--muted);font-size:0.8rem;text-align:center"></div>
  </div>
</aside>

<div id="app">
  <header class="header">
    <div class="logo">Spell<span>Duel</span> <em>AI</em></div>
    <div style="display:flex;align-items:center;gap:10px">
      <div class="player-badge" id="playerBadge" style="display:none">
        <div class="dot"></div>
        <span id="playerNameBadge">—</span>
      </div>
      <button class="mobile-hamburger-btn" id="hamburgerBtn" style="display:none" onclick="openSidebar()">☰</button>
    </div>
  </header>

  <!-- LOGIN SCREEN -->
  <div class="screen active" id="screen-setup">
    <div class="setup-hero">
      <h1>Spell<span style="color:var(--accent)">Duel</span> <em style="color:var(--accent2);font-style:normal">AI</em></h1>
      <p style="color:var(--muted);margin-bottom:28px">Masuk dengan username untuk menyimpan skor & progress kamu.</p>

      <div style="max-width:380px;margin:0 auto">
        <div class="input-group">
          <input class="input" id="nameInput" placeholder="Ketik username kamu…" maxlength="20" autocomplete="off"
            onkeydown="if(event.key==='Enter')submitName(event)" style="font-size:1.05rem;padding:14px 18px;text-align:center" />
        </div>
        <button class="btn btn-primary btn-full" onclick="submitName(event)" style="margin-bottom:20px;font-size:1rem">
          Masuk / Daftar →
        </button>

        <!-- Rules box -->
        <div style="background:rgba(239,68,68,0.08);border:1px solid rgba(239,68,68,0.25);border-radius:14px;padding:18px 20px;text-align:left">
          <div style="font-size:0.78rem;font-weight:800;color:var(--danger);text-transform:uppercase;letter-spacing:0.1em;margin-bottom:10px">⚠️ Peraturan Akun</div>
          <div style="font-size:0.82rem;color:var(--muted);line-height:1.9">
            📅 <b style="color:var(--text)">Akun otomatis dihapus</b> jika tidak login selama <b style="color:var(--danger)">30 hari</b><br>
            💀 Semua <b style="color:var(--text)">skor & progress akan hilang</b> selamanya<br>
            🔑 <b style="color:var(--text)">Tidak ada password</b> — cukup username untuk masuk<br>
            📊 Skor disimpan permanen selama kamu aktif login
          </div>
        </div>

        <div style="margin-top:20px;display:flex;justify-content:center;gap:20px;flex-wrap:wrap">
          <span style="color:var(--muted);font-size:0.8rem">🎯 Spelling Solo</span>
          <span style="color:var(--muted);font-size:0.8rem">🌐 Translation</span>
          <span style="color:var(--muted);font-size:0.8rem">👥 Multiplayer</span>
          <span style="color:var(--muted);font-size:0.8rem">🏆 Leaderboard</span>
        </div>
      </div>
    </div>
  </div>

  <!-- LOBBY SCREEN -->
  <div class="screen" id="screen-lobby">
    <div class="tabs">
      <button class="tab active" id="tabl-browse" onclick="navGoTo('browse')">Browse Lobbies</button>
      <button class="tab" id="tabl-create" onclick="navGoTo('create')">Create Room</button>
      <button class="tab" id="tabl-solo" onclick="navGoTo('solo')">🎯 Solo</button>
      <button class="tab" id="tabl-trans" onclick="navGoTo('trans')">🌐 Translation</button>
      <button class="tab" id="tabl-lb" onclick="navGoTo('lb')">Leaderboard</button>
    </div>

    <!-- Browse -->
    <div id="tab-browse">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
        <span style="color:var(--muted);font-size:0.85rem" id="lobbyCount">0 public rooms</span>
        <button class="btn btn-secondary btn-sm" onclick="requestLobbies()">↺ Refresh</button>
      </div>
      <div class="lobby-list" id="lobbyList">
        <div class="empty-state">
          <div class="icon">🏛️</div>
          <div>No rooms available</div>
          <div style="font-size:0.8rem;margin-top:6px">Create one and be the host!</div>
        </div>
      </div>
    </div>

    <!-- Create -->
    <div id="tab-create" style="display:none">
      <div class="card" style="max-width:420px">
        <div class="card-title">🎮 Create a Room</div>
        <div class="create-form">
          <div class="input-group">
            <label class="input-label">Room Name</label>
            <input class="input" id="lobbyName" placeholder="My Spelling Arena" maxlength="30" />
          </div>
          <div class="gap-row">
            <div class="input-group">
              <label class="input-label">Difficulty</label>
              <select class="input" id="lobbyDiff">
                <option value="easy">Easy</option>
                <option value="medium" selected>Medium</option>
                <option value="hard">Hard</option>
              </select>
            </div>
            <div class="input-group">
              <label class="input-label">Rounds</label>
              <select class="input" id="lobbyRounds">
                <option value="3">3 Rounds</option>
                <option value="5" selected>5 Rounds</option>
                <option value="10">10 Rounds</option>
              </select>
            </div>
          </div>
          <div class="input-group">
            <label class="input-label">Max Players</label>
            <select class="input" id="lobbyMax">
              <option value="2">2 Players</option>
              <option value="4">4 Players</option>
              <option value="6" selected>6 Players</option>
              <option value="10">10 Players</option>
            </select>
          </div>
          <button class="btn btn-primary btn-full" onclick="createLobby()">🚀 Create Room</button>
        </div>
      </div>
    </div>

    <!-- Leaderboard -->
    <div id="tab-lb" style="display:none">
      <div class="card">
        <div class="card-title">🏆 Global Leaderboard</div>
        <div class="lb-header">
          <div>#</div><div>Player</div><div>Total Pts</div><div>Games</div>
        </div>
        <div id="lbRows">
          <div style="padding:30px;text-align:center;color:var(--muted)">No scores yet — play a game!</div>
        </div>
      </div>
    </div>

    <!-- Solo Setup -->
    <div id="tab-solo" style="display:none">
      <div class="solo-setup-card">
        <div class="card-title" style="font-size:1.3rem;margin-bottom:20px">🎯 Solo Practice</div>
        <p style="color:var(--muted);font-size:0.88rem;margin-bottom:24px">
          Train on your own. AI generates words, TTS reads them aloud — type what you hear.
          3 lives per game, streaks give bonus points!
        </p>

        <div class="input-group">
          <label class="input-label">Difficulty</label>
          <div class="mode-cards" id="soloModeCards">
            <div class="mode-card selected" onclick="selectSoloDiff('easy', this)">
              <div class="mode-card-icon">🌱</div>
              <div class="mode-card-name">Easy</div>
              <div class="mode-card-desc">Short common words</div>
            </div>
            <div class="mode-card" onclick="selectSoloDiff('medium', this)">
              <div class="mode-card-icon">⚡</div>
              <div class="mode-card-name">Medium</div>
              <div class="mode-card-desc">Everyday vocabulary</div>
            </div>
            <div class="mode-card" onclick="selectSoloDiff('hard', this)">
              <div class="mode-card-icon">🔥</div>
              <div class="mode-card-name">Hard</div>
              <div class="mode-card-desc">Complex spellings</div>
            </div>
            <div class="mode-card" onclick="selectSoloDiff('expert', this)">
              <div class="mode-card-icon">💀</div>
              <div class="mode-card-name">Expert</div>
              <div class="mode-card-desc">Spelling bee level</div>
            </div>
          </div>
        </div>

        <div class="input-group">
          <label class="input-label">Number of Rounds</label>
          <select class="input" id="soloRounds">
            <option value="5" selected>5 Rounds</option>
            <option value="10">10 Rounds</option>
            <option value="20">20 Rounds</option>
            <option value="999">Endless (until 0 lives)</option>
          </select>
        </div>

        <div class="card" style="margin-bottom:20px;padding:16px">
          <div style="font-size:0.78rem;color:var(--muted);line-height:1.8">
            ❤️ <b style="color:var(--text)">3 lives</b> — wrong answer or skip costs 1 life<br>
            ⚡ <b style="color:var(--text)">Streak bonus</b> — 3+ correct in a row = extra points<br>
            ⏱️ <b style="color:var(--text)">Speed bonus</b> — faster answer = more points<br>
            🏆 <b style="color:var(--text)">Score counts</b> — added to global leaderboard
          </div>
        </div>

        <button class="btn btn-primary btn-full" onclick="startSolo()">🎯 Start Solo Practice</button>
      </div>
    </div>

    <!-- Translation Setup -->
    <div id="tab-trans" style="display:none">
      <div class="solo-setup-card">
        <div class="card-title" style="font-size:1.3rem;margin-bottom:8px">🌐 Mode Translation</div>
        <p style="color:var(--muted);font-size:0.85rem;margin-bottom:24px">
          AI buat kalimat dalam bahasa asal — kamu terjemahkan ke bahasa target. AI nilai jawabanmu: Benar, Mendekati, atau Salah.
        </p>

        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px">
          <div class="input-group">
            <label class="input-label">Bahasa Asal (Source)</label>
            <input class="input" id="transSource" placeholder="misal: English" value="English" maxlength="30" />
          </div>
          <div class="input-group">
            <label class="input-label">Bahasa Target</label>
            <input class="input" id="transTarget" placeholder="misal: Indonesian" value="Indonesian" maxlength="30" />
          </div>
        </div>

        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px">
          <div class="input-group">
            <label class="input-label">Min Kata per Kalimat</label>
            <select class="input" id="transMinWords">
              <option value="2">2 kata</option>
              <option value="3" selected>3 kata</option>
              <option value="4">4 kata</option>
              <option value="5">5 kata</option>
              <option value="6">6 kata</option>
            </select>
          </div>
          <div class="input-group">
            <label class="input-label">Max Kata per Kalimat</label>
            <select class="input" id="transMaxWords">
              <option value="4">4 kata</option>
              <option value="5">5 kata</option>
              <option value="6" selected>6 kata</option>
              <option value="8">8 kata</option>
              <option value="10">10 kata</option>
              <option value="15">15 kata</option>
            </select>
          </div>
        </div>

        <div class="input-group" style="margin-bottom:20px">
          <label class="input-label">Jumlah Ronde</label>
          <select class="input" id="transRounds">
            <option value="5" selected>5 Ronde</option>
            <option value="10">10 Ronde</option>
            <option value="20">20 Ronde</option>
          </select>
        </div>

        <div class="card" style="margin-bottom:20px;padding:16px">
          <div style="font-size:0.78rem;color:var(--muted);line-height:1.9">
            🌐 <b style="color:var(--text)">AI buat kalimat</b> sesuai bahasa & panjang yang kamu pilih<br>
            ✅ <b style="color:var(--success)">Benar</b> — terjemahan tepat, poin penuh + bonus kecepatan<br>
            🟡 <b style="color:var(--accent3)">Mendekati</b> — hampir benar, bisa coba lagi tanpa kurang nyawa<br>
            ❌ <b style="color:var(--danger)">Salah</b> — kurang 1 nyawa, lanjut ke kalimat berikutnya<br>
            ❤️ <b style="color:var(--text)">3 nyawa</b> — habis nyawa = game over
          </div>
        </div>

        <button class="btn btn-primary btn-full" style="background:linear-gradient(135deg,#7c3aed,#06b6d4)" onclick="startTrans()">
          🌐 Mulai Translation
        </button>
      </div>
    </div>
  </div><!-- end screen-lobby -->

  <!-- TRANSLATION GAME SCREEN -->
  <div class="screen" id="screen-trans">
    <div class="game-header">
      <div>
        <div class="round-info" id="transModeLine">🌐 Translation · Ronde</div>
        <div class="round-num" id="transRoundNum">1 / 5</div>
      </div>
      <div style="display:flex;align-items:center;gap:12px">
        <div class="streak-fire" id="transStreak">🔥 0 streak</div>
        <div class="timer-ring">
          <svg width="64" height="64" viewBox="0 0 64 64">
            <circle class="track" cx="32" cy="32" r="28" />
            <circle class="progress" id="transTimerArc" cx="32" cy="32" r="28"
              stroke-dasharray="175.9" stroke-dashoffset="0" />
          </svg>
          <div class="label" id="transTimerLabel">45</div>
        </div>
      </div>
    </div>

    <div class="solo-stats-bar">
      <div class="solo-stat">
        <div class="solo-stat-val" id="transScore" style="color:var(--accent)">0</div>
        <div class="solo-stat-label">Skor</div>
      </div>
      <div class="solo-stat">
        <div class="lives-display" id="transLives">❤️❤️❤️</div>
        <div class="solo-stat-label">Nyawa</div>
      </div>
      <div class="solo-stat">
        <div class="solo-stat-val" id="transCorrectCount" style="color:var(--success)">0</div>
        <div class="solo-stat-label">Benar</div>
      </div>
      <div class="solo-stat">
        <div class="solo-stat-val" id="transBestStreak" style="color:var(--accent3)">0</div>
        <div class="solo-stat-label">Best Streak</div>
      </div>
    </div>

    <!-- Phrase to translate -->
    <div class="hint-box" style="margin-bottom:20px">
      <div class="hint-label" id="transFromLabel">🌐 Terjemahkan dari English ke Indonesian</div>
      <div id="transChecking" style="display:none;color:var(--accent2);font-size:0.85rem;margin-bottom:8px">⏳ AI sedang menilai...</div>
      <div class="hint-text" id="transPhraseText" style="font-size:1.4rem;letter-spacing:0.01em">Memuat kalimat…</div>
    </div>

    <div class="answer-area">
      <textarea
        id="transAnswerInput"
        placeholder="Ketik terjemahan kamu di sini…"
        autocomplete="off"
        autocorrect="off"
        spellcheck="false"
        rows="3"
        style="width:100%;max-width:520px;background:var(--surface2);border:2px solid var(--border);border-radius:14px;padding:16px 20px;color:var(--text);font-family:'Syne',sans-serif;font-size:1rem;outline:none;resize:vertical;transition:border-color 0.2s;line-height:1.6"
        onkeydown="handleTransKey(event)"
        disabled
      ></textarea>
      <div style="display:flex;gap:10px;flex-wrap:wrap;justify-content:center">
        <button class="btn btn-primary" id="transSubmitBtn" onclick="submitTransAnswer()" disabled>Kirim Terjemahan →</button>
        <button class="btn btn-secondary" onclick="skipTransWord()">Lewati (−1 ❤️)</button>
        <button class="btn btn-secondary btn-sm" onclick="quitTrans()" style="opacity:0.5">Keluar</button>
      </div>
    </div>

    <div class="events-log" id="transEventsLog" style="margin-top:16px"></div>
  </div>

  <!-- TRANSLATION RESULT SCREEN -->
  <div class="screen" id="screen-trans-over">
    <div class="game-over-wrap">
      <div class="game-over-title" id="transOverTitle">🌐 Selesai!</div>
      <div class="game-over-sub" id="transOverSub">Hasil terjemahan kamu</div>
      <div class="solo-result-grid">
        <div class="result-stat"><div class="result-stat-val gold" id="transFinalScore">0</div><div class="result-stat-label">Total Skor</div></div>
        <div class="result-stat"><div class="result-stat-val green" id="transFinalCorrect">0</div><div class="result-stat-label">Kalimat Benar</div></div>
        <div class="result-stat"><div class="result-stat-val cyan" id="transFinalStreak">0</div><div class="result-stat-label">Best Streak</div></div>
        <div class="result-stat"><div class="result-stat-val purple" id="transFinalTime">0s</div><div class="result-stat-label">Durasi</div></div>
      </div>
      <div class="card" style="margin-bottom:24px">
        <div class="card-title">🏆 Leaderboard Global <span class="badge">Updated</span></div>
        <div class="lb-header"><div>#</div><div>Player</div><div>Total Pts</div><div>Games</div></div>
        <div id="transFinalLb"></div>
      </div>
      <div style="display:flex;gap:12px;justify-content:center;flex-wrap:wrap">
        <button class="btn btn-primary" onclick="playAgainTrans()">🔄 Main Lagi</button>
        <button class="btn btn-secondary" onclick="backToLobbyFromTrans()">← Menu Utama</button>
      </div>
    </div>
  </div>

  <!-- SOLO GAME SCREEN -->
  <div class="screen" id="screen-solo">
    <div class="game-header">
      <div>
        <div class="round-info">Solo · Round</div>
        <div class="round-num" id="soloRoundNum">1 / 5</div>
      </div>
      <div style="display:flex;align-items:center;gap:12px">
        <div class="streak-fire" id="soloStreak">🔥 0 streak</div>
        <div class="timer-ring">
          <svg width="64" height="64" viewBox="0 0 64 64">
            <circle class="track" cx="32" cy="32" r="28" />
            <circle class="progress" id="soloTimerArc" cx="32" cy="32" r="28"
              stroke-dasharray="175.9" stroke-dashoffset="0" />
          </svg>
          <div class="label" id="soloTimerLabel">30</div>
        </div>
      </div>
    </div>

    <div class="solo-stats-bar">
      <div class="solo-stat">
        <div class="solo-stat-val" id="soloScore" style="color:var(--accent)">0</div>
        <div class="solo-stat-label">Score</div>
      </div>
      <div class="solo-stat">
        <div class="lives-display" id="soloLives">❤️❤️❤️</div>
        <div class="solo-stat-label">Lives</div>
      </div>
      <div class="solo-stat">
        <div class="solo-stat-val" id="soloCorrectCount" style="color:var(--success)">0</div>
        <div class="solo-stat-label">Correct</div>
      </div>
      <div class="solo-stat">
        <div class="solo-stat-val" id="soloBestStreak" style="color:var(--accent3)">0</div>
        <div class="solo-stat-label">Best Streak</div>
      </div>
    </div>

    <div class="hint-box">
      <div class="hint-label">🔊 Dengarkan & Eja</div>
      <div style="margin-bottom:16px;color:var(--muted);font-size:0.9rem">Tekan tombol di bawah untuk mendengar kata, lalu eja di kolom jawaban.</div>
      <button class="tts-btn" id="soloTtsBtn" onclick="soloSpeakHint()">
        <span>▶</span> Dengarkan
      </button>
      <div class="word-blanks" id="soloWordBlanks" style="display:none"></div>
      <div class="word-length" id="soloWordLengthText" style="display:none"></div>
    </div>

    <div class="answer-area">
      <input
        class="spell-input"
        id="soloSpellInput"
        placeholder="ketik ejaan kata…"
        autocomplete="off"
        autocorrect="off"
        spellcheck="false"
        onkeydown="handleSoloKey(event)"
        oninput="updateSoloBlanks(this.value)"
        disabled
      />
      <div style="display:flex;gap:10px">
        <button class="btn btn-primary" id="soloSubmitBtn" onclick="submitSoloAnswer()" disabled>Kirim →</button>
        <button class="btn btn-secondary" onclick="skipSoloWord()">Lewati (−1 ❤️)</button>
        <button class="btn btn-secondary btn-sm" onclick="quitSolo()" style="opacity:0.5">Keluar</button>
      </div>
    </div>

    <div class="events-log" id="soloEventsLog"></div>
  </div>

  <!-- SOLO RESULT SCREEN -->
  <div class="screen" id="screen-solo-over">
    <div class="game-over-wrap">
      <div class="game-over-title" id="soloOverTitle">🎯 Round Complete!</div>
      <div class="game-over-sub" id="soloOverSub">Great job!</div>

      <div class="solo-result-grid">
        <div class="result-stat">
          <div class="result-stat-val gold" id="soloFinalScore">0</div>
          <div class="result-stat-label">Total Score</div>
        </div>
        <div class="result-stat">
          <div class="result-stat-val green" id="soloFinalCorrect">0</div>
          <div class="result-stat-label">Words Correct</div>
        </div>
        <div class="result-stat">
          <div class="result-stat-val cyan" id="soloFinalStreak">0</div>
          <div class="result-stat-label">Best Streak</div>
        </div>
        <div class="result-stat">
          <div class="result-stat-val purple" id="soloFinalTime">0s</div>
          <div class="result-stat-label">Time Played</div>
        </div>
      </div>

      <div class="card" style="margin-bottom:24px">
        <div class="card-title">🏆 Global Leaderboard <span class="badge">Updated</span></div>
        <div class="lb-header"><div>#</div><div>Player</div><div>Total Pts</div><div>Games</div></div>
        <div id="soloFinalLb"></div>
      </div>

      <div style="display:flex;gap:12px;justify-content:center;flex-wrap:wrap">
        <button class="btn btn-primary" onclick="playAgainSolo()">🔄 Play Again</button>
        <button class="btn btn-secondary" onclick="backToLobbyFromSolo()">← Main Menu</button>
      </div>
    </div>
  </div>

  <!-- WAITING ROOM -->
  <div class="screen" id="screen-waiting">
    <div class="waiting-header">
      <div>
        <div class="waiting-title" id="waitingTitle">Waiting Room</div>
        <div class="waiting-subtitle" id="waitingSubtitle">Waiting for players…</div>
      </div>
      <div style="display:flex;gap:10px;flex-wrap:wrap">
        <button class="btn btn-secondary btn-sm" onclick="leaveLobby()">← Leave</button>
        <button class="btn btn-primary" id="startBtn" style="display:none" onclick="startGame()">▶ Start Game</button>
      </div>
    </div>
    <div class="players-grid" id="waitingPlayers"></div>
    <div class="card">
      <div style="font-size:0.8rem;color:var(--muted)">
        ⌛ Waiting for host to start the game… Make sure all players are ready!
      </div>
    </div>
  </div>

  <!-- GAME SCREEN -->
  <div class="screen" id="screen-game">
    <div class="game-header">
      <div>
        <div class="round-info">Round</div>
        <div class="round-num" id="roundNum">1 / 5</div>
      </div>
      <div class="timer-ring" id="timerRing">
        <svg width="64" height="64" viewBox="0 0 64 64">
          <circle class="track" cx="32" cy="32" r="28" />
          <circle class="progress" id="timerArc" cx="32" cy="32" r="28"
            stroke-dasharray="175.9"
            stroke-dashoffset="0" />
        </svg>
        <div class="label" id="timerLabel">30</div>
      </div>
    </div>

    <div class="hint-box">
      <div class="hint-label">🔊 Listen & Spell</div>
      <div class="hint-text" id="hintText">Loading…</div>
      <button class="tts-btn" id="ttsBtn" onclick="speakHint()">
        <span>▶</span> Hear Again
      </button>
      <div class="word-blanks" id="wordBlanks"></div>
      <div class="word-length" id="wordLengthText"></div>
    </div>

    <div class="answer-area">
      <input
        class="spell-input"
        id="spellInput"
        placeholder="type one word…"
        autocomplete="off"
        autocorrect="off"
        spellcheck="false"
        onkeydown="handleSpellKey(event)"
        oninput="updateBlanks(this.value)"
        disabled
      />
      <button class="btn btn-primary" id="submitBtn" onclick="submitAnswer()" disabled>
        Submit →
      </button>
    </div>

    <div class="scoreboard">
      <div class="scoreboard-title">Live Scores</div>
      <div id="gameScores"></div>
    </div>

    <div class="events-log" id="eventsLog"></div>
  </div>

  <!-- GAME OVER -->
  <div class="screen" id="screen-gameover">
    <div class="game-over-wrap">
      <div class="game-over-title">🎉 Game Over!</div>
      <div class="game-over-sub">Final results</div>
      <div class="winner-spotlight" id="winnerSpotlight">
        <div class="winner-trophy">🏆</div>
        <div class="winner-name" id="winnerName">—</div>
        <div class="winner-score" id="winnerScore">0 pts</div>
      </div>
      <div class="card" style="margin-bottom:24px">
        <div class="card-title">Final Scores</div>
        <div id="finalScores"></div>
      </div>
      <div class="card" style="margin-bottom:28px">
        <div class="card-title">🏆 Global Leaderboard <span class="badge">Updated</span></div>
        <div class="lb-header"><div>#</div><div>Player</div><div>Total Pts</div><div>Games</div></div>
        <div id="finalLb"></div>
      </div>
      <button class="btn btn-primary" onclick="backToLobby()">Play Again</button>
    </div>
  </div>
</div>

<!-- Notifications -->
<div id="notif"></div>
<div class="conn-status conn-err" id="connStatus">Connecting…</div>

<script>
// ── State ────────────────────────────────────────────────
const state = {
  ws: null,
  playerId: null,
  playerName: null,
  lobbyId: null,
  isHost: false,
  currentHint: null,
  currentWordLength: 0,
  timerInterval: null,
  timerSecs: 30,
  answered: false,
  speaking: false
};

// ── WebSocket ────────────────────────────────────────────
function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const wsUrl = `${proto}://${location.host}/ws`;
  state.ws = new WebSocket(wsUrl);

  state.ws.onopen = () => {
    document.getElementById('connStatus').className = 'conn-status conn-ok';
    document.getElementById('connStatus').textContent = '● Connected';
  };

  state.ws.onclose = () => {
    document.getElementById('connStatus').className = 'conn-status conn-err';
    document.getElementById('connStatus').textContent = '● Disconnected';
    setTimeout(connect, 3000);
  };

  state.ws.onerror = () => {};

  state.ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    handleMessage(msg);
  };
}

function send(obj) {
  if (state.ws && state.ws.readyState === 1) {
    state.ws.send(JSON.stringify(obj));
  }
}

// ── Hash-based Routing Map ────────────────────────────
const ROUTE_MAP = {
  'browse': 'tab-browse',
  'create': 'tab-create',
  'solo':   'tab-solo',
  'trans':  'tab-trans',
  'lb':     'tab-lb'
};

// ── Message Handler ──────────────────────────────────────
function handleMessage(msg) {
  switch (msg.type) {
    case 'connected':
      state.playerId = msg.playerId;
      // Belum login — tetap di screen setup
      break;

    case 'name_set':
      break;

    case 'lobby_list':
      renderLobbyList(msg.lobbies || []);
      break;

    case 'leaderboard':
      renderLeaderboard(msg.data || [], 'lbRows');
      break;

    case 'lobby_created':
      state.lobbyId = msg.lobby.id;
      state.isHost = true;
      showWaitingRoom(msg.lobby, []);
      break;

    case 'lobby_joined':
      state.lobbyId = msg.lobby.id;
      state.isHost = msg.lobby.hostId === state.playerId;
      showWaitingRoom(msg.lobby, msg.players || []);
      break;

    case 'player_joined':
      renderWaitingPlayers(msg.players, state.lobbyId);
      addEvent(`👤 ${msg.playerName} joined`, 'ev-info');
      notify(`${msg.playerName} joined the room`, 'info');
      break;

    case 'player_left':
      renderWaitingPlayers(msg.players, state.lobbyId);
      addEvent(`👋 ${msg.playerName} left`, 'ev-info');
      break;

    case 'left_lobby':
      state.lobbyId = null;
      state.isHost = false;
      showScreen('screen-lobby');
      break;

    case 'game_start':
      showScreen('screen-game');
      clearEvents();
      addEvent('🎮 Game started!', 'ev-info');
      break;

    case 'new_round':
      startRound(msg);
      break;

    case 'correct_answer':
      addEvent(`✅ ${msg.playerName} spelled "${msg.word}" correctly! +${msg.points}pts`, 'ev-correct');
      if (msg.playerId === state.playerId) {
        showSpellFeedback(true);
        notify(`+${msg.points} points!`, 'success');
      }
      clearTimer();
      renderGameScores(msg.scores);
      break;

    case 'wrong_answer':
      if (msg.playerId === state.playerId) {
        showSpellFeedback(false);
        state.answered = false;
        document.getElementById('spellInput').value = '';
        document.getElementById('spellInput').disabled = false;
        document.getElementById('submitBtn').disabled = false;
      }
      addEvent(`❌ ${msg.playerName} typed "${msg.attempt}"`, 'ev-wrong');
      break;

    case 'round_timeout':
      clearTimer();
      addEvent(`⏱️ Time's up! Word was: "${msg.correctWord}"`, 'ev-info');
      notify(`Time's up! It was: ${msg.correctWord}`, 'info');
      break;

    case 'game_over':
      clearTimer();
      showGameOver(msg.finalScores, msg.leaderboard);
      break;

    case 'error':
      notify(msg.msg, 'error');
      break;

    // ── SOLO MESSAGES ──────────────────────────────────
    case 'solo_started':
      soloState.active = true;
      soloState.score = 0;
      soloState.lives = 3;
      soloState.streak = 0;
      soloState.bestStreak = 0;
      soloState.correctCount = 0;
      soloSyncStats();
      clearSoloEvents();
      showScreen('screen-solo');
      break;

    case 'solo_round':
      soloStartRound(msg);
      break;

    case 'solo_correct':
      soloState.score = msg.score;
      soloState.streak = msg.streak;
      soloState.bestStreak = Math.max(soloState.bestStreak, msg.streak);
      soloState.correctCount++;
      soloState.answered = true;
      showSoloFeedback(true);
      soloSyncStats();
      let ptMsg = `+${msg.pts}pts`;
      if (msg.streakBonus > 0) ptMsg += ` (🔥 streak +${msg.streakBonus})`;
      addSoloEvent(`✅ Benar! Kata: "${msg.word}" ${ptMsg}`, 'ev-correct');
      notify(`+${msg.pts} poin! Benar ✅`, 'success');
      clearSoloTimer();
      document.getElementById('soloSubmitBtn').disabled = true;
      document.getElementById('soloSpellInput').disabled = true;
      break;

    case 'solo_wrong':
      soloState.lives = msg.lives;
      soloState.streak = 0;
      soloState.answered = false;
      soloSyncStats();
      showSoloFeedback(false);
      addSoloEvent(`❌ Salah: "${msg.attempt}" — coba lagi! (${msg.lives} nyawa tersisa)`, 'ev-wrong');
      document.getElementById('soloSpellInput').value = '';
      document.getElementById('soloSpellInput').disabled = false;
      document.getElementById('soloSubmitBtn').disabled = false;
      document.getElementById('soloSpellInput').focus();
      break;

    case 'solo_close':
      soloState.answered = false;
      showSoloFeedback(false);
      addSoloEvent(`🟡 Mendekati: "${msg.attempt}" — hampir benar, coba lagi!`, 'ev-info');
      notify('Hampir benar! Coba lagi 🟡', 'info');
      document.getElementById('soloSpellInput').value = '';
      document.getElementById('soloSpellInput').disabled = false;
      document.getElementById('soloSubmitBtn').disabled = false;
      document.getElementById('soloSpellInput').focus();
      break;

    case 'solo_skipped':
      soloState.lives = msg.lives;
      soloState.streak = 0;
      soloState.answered = true;
      soloSyncStats();
      addSoloEvent(`⏭️ Dilewati — kata: "${msg.word}" (${msg.lives} nyawa tersisa)`, 'ev-info');
      clearSoloTimer();
      break;

    case 'solo_over':
      clearSoloTimer();
      soloState.active = false;
      soloState.currentHint = null;
      if ('speechSynthesis' in window) window.speechSynthesis.cancel();
      showSoloOver(msg);
      break;

    // ── TRANSLATION MESSAGES ─────────────────────────────
    case 'trans_started':
      transState.active = true;
      transState.score = 0;
      transState.lives = 3;
      transState.streak = 0;
      transState.bestStreak = 0;
      transState.correctCount = 0;
      transSyncStats();
      clearTransEvents();
      showScreen('screen-trans');
      break;

    case 'trans_round':
      transStartRound(msg);
      break;

    case 'trans_checking':
      document.getElementById('transChecking').style.display = 'block';
      document.getElementById('transSubmitBtn').disabled = true;
      break;

    case 'trans_correct':
      transState.score = msg.score;
      transState.streak = msg.streak;
      transState.bestStreak = Math.max(transState.bestStreak, msg.streak);
      transState.correctCount++;
      transState.answered = true;
      document.getElementById('transChecking').style.display = 'none';
      showTransFeedback(true);
      transSyncStats();
      addTransEvent(`✅ Benar! +${msg.pts} poin${msg.streakBonus > 0 ? ` (🔥 streak +${msg.streakBonus})` : ''}`, 'ev-correct');
      notify(`+${msg.pts} poin! Terjemahan benar ✅`, 'success');
      clearTransTimer();
      document.getElementById('transSubmitBtn').disabled = true;
      document.getElementById('transAnswerInput').disabled = true;
      break;

    case 'trans_close':
      document.getElementById('transChecking').style.display = 'none';
      showTransFeedback(false);
      addTransEvent(`🟡 Mendekati! Coba lagi — hampir benar`, 'ev-info');
      notify('Hampir benar! Coba lagi 🟡', 'info');
      document.getElementById('transAnswerInput').value = '';
      document.getElementById('transAnswerInput').disabled = false;
      document.getElementById('transSubmitBtn').disabled = false;
      document.getElementById('transAnswerInput').focus();
      break;

    case 'trans_wrong':
      transState.lives = msg.lives;
      transState.streak = 0;
      transState.answered = true;
      document.getElementById('transChecking').style.display = 'none';
      showTransFeedback(false);
      transSyncStats();
      addTransEvent(`❌ Salah (${msg.lives} nyawa tersisa) — lanjut ke kalimat berikutnya`, 'ev-wrong');
      notify(`Salah ❌ (${msg.lives} nyawa)`, 'error');
      clearTransTimer();
      document.getElementById('transSubmitBtn').disabled = true;
      document.getElementById('transAnswerInput').disabled = true;
      break;

    case 'trans_skipped':
      transState.lives = msg.lives;
      transState.streak = 0;
      transState.answered = true;
      transSyncStats();
      addTransEvent(`⏭️ Dilewati (${msg.lives} nyawa tersisa)`, 'ev-info');
      clearTransTimer();
      break;

    case 'trans_over':
      clearTransTimer();
      transState.active = false;
      showTransOver(msg);
      break;

    case 'login_ok':
      state.playerName = msg.username;
      document.getElementById('playerNameBadge').textContent = msg.username;
      document.getElementById('playerBadge').style.display = 'flex';
      renderLobbyList(msg.lobbies || []);
      renderLeaderboard(msg.leaderboard || [], 'lbRows');
      if (msg.isNew) notify(`Selamat datang, ${msg.username}! Akun baru dibuat 🎉`, 'success');
      else notify(`Selamat datang kembali, ${msg.username}! Skor: ${msg.score} pts`, 'info');
      showNavBar(msg.username);
      showScreen('screen-lobby');
      // Navigate to hash route if present, else default browse
      const initHash = location.hash.replace('#','') || 'browse';
      const initTab = ROUTE_MAP[initHash] || 'tab-browse';
      switchTab(initTab);
      if (!location.hash) location.hash = 'browse';
      break;

    case 'login_error':
      notify(msg.msg, 'error');
      break;
  }
}

// ── Setup / Login ─────────────────────────────────────────
function submitName(e) {
  if (e && e.preventDefault) e.preventDefault();
  const name = document.getElementById('nameInput').value.trim();
  if (!name) { notify('Username tidak boleh kosong', 'error'); return; }
  send({ type: 'login', username: name });
}

// ── Screens ──────────────────────────────────────────────
function showScreen(id) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById(id).classList.add('active');
  // Update hash to reflect current screen (only for lobby sub-tabs, managed separately)
  if (id === 'screen-lobby') {
    // don't touch hash here, navGoTo handles it
  }
}

function switchTab(tabId) {
  ['tab-browse','tab-create','tab-solo','tab-trans','tab-lb'].forEach(t => {
    const el = document.getElementById(t);
    if (el) el.style.display = t === tabId ? 'block' : 'none';
  });
  // Update inline tabs active state
  const keys = ['browse','create','solo','trans','lb'];
  const tabIds = ['tab-browse','tab-create','tab-solo','tab-trans','tab-lb'];
  document.querySelectorAll('.tab').forEach((t, i) => {
    t.classList.toggle('active', tabIds[i] === tabId);
  });
  // Update floating nav & sidebar active state
  keys.forEach(k => {
    const nBtn = document.getElementById('nav-' + k);
    const sBtn = document.getElementById('snav-' + k);
    const isActive = tabId === 'tab-' + k;
    if (nBtn) nBtn.classList.toggle('active', isActive);
    if (sBtn) sBtn.classList.toggle('active', isActive);
  });
  if (tabId === 'tab-browse') requestLobbies();
  if (tabId === 'tab-lb') send({ type: 'get_leaderboard' });
}

// ── Hash-based Routing ─────────────────────────────────

function navGoTo(key) {
  location.hash = key;
}

function handleHashChange() {
  const hash = location.hash.replace('#', '') || 'browse';
  const tabId = ROUTE_MAP[hash];
  if (!tabId) return;

  // Only navigate tabs if user is logged in and on lobby screen
  if (!state.playerName) return;
  const lobbyScreen = document.getElementById('screen-lobby');
  if (!lobbyScreen.classList.contains('active')) {
    showScreen('screen-lobby');
  }
  switchTab(tabId);
}

// ── Sidebar controls ──────────────────────────────────
function openSidebar() {
  document.getElementById('mobileSidebar').classList.add('open');
  document.getElementById('sidebarOverlay').classList.add('visible');
}
function closeSidebar() {
  document.getElementById('mobileSidebar').classList.remove('open');
  document.getElementById('sidebarOverlay').classList.remove('visible');
}

// ── Show/hide nav based on login ──────────────────────
function showNavBar(name) {
  // Floating nav (desktop)
  const nav = document.getElementById('floatingNav');
  if (window.innerWidth >= 768) nav.style.display = 'flex';
  // Hamburger (mobile)
  document.getElementById('hamburgerBtn').style.display = 'flex';
  // Sidebar player name
  document.getElementById('sidebarPlayerName').textContent = '👤 ' + name;
}

// ── Lobby ────────────────────────────────────────────────
function requestLobbies() { send({ type: 'get_lobbies' }); }

function renderLobbyList(lobbies) {
  const el = document.getElementById('lobbyList');
  document.getElementById('lobbyCount').textContent = `${lobbies.length} public room${lobbies.length !== 1 ? 's' : ''}`;
  if (!lobbies.length) {
    el.innerHTML = `<div class="empty-state"><div class="icon">🏛️</div><div>No rooms available</div><div style="font-size:0.8rem;margin-top:6px">Create one and be the host!</div></div>`;
    return;
  }
  el.innerHTML = lobbies.map(l => `
    <div class="lobby-item" onclick="joinLobby('${l.id}')">
      <div>
        <div class="lobby-item-name">${esc(l.name)}</div>
        <div class="lobby-item-meta">
          <span>👥 ${l.playerCount}/${l.maxPlayers}</span>
          <span>🔄 ${l.maxRounds} rounds</span>
          <span class="diff-badge diff-${l.difficulty}">${l.difficulty}</span>
        </div>
      </div>
      <button class="btn btn-cyan btn-sm">Join →</button>
    </div>
  `).join('');
}

function createLobby() {
  const name = document.getElementById('lobbyName').value.trim() || `${state.playerName}'s Room`;
  send({
    type: 'create_lobby',
    settings: {
      name,
      difficulty: document.getElementById('lobbyDiff').value,
      maxRounds: parseInt(document.getElementById('lobbyRounds').value),
      maxPlayers: parseInt(document.getElementById('lobbyMax').value)
    }
  });
}

function joinLobby(id) {
  send({ type: 'join_lobby', lobbyId: id });
}

function leaveLobby() {
  send({ type: 'leave_lobby' });
}

// ── Waiting Room ─────────────────────────────────────────
function showWaitingRoom(lobby, players) {
  document.getElementById('waitingTitle').textContent = lobby.name;
  document.getElementById('waitingSubtitle').textContent =
    `${lobby.difficulty} · ${lobby.maxRounds} rounds · up to ${lobby.maxPlayers} players`;
  const startBtn = document.getElementById('startBtn');
  startBtn.style.display = (lobby.hostId === state.playerId) ? 'inline-flex' : 'none';
  renderWaitingPlayers(players, lobby.id, lobby.hostId);
  showScreen('screen-waiting');
}

function renderWaitingPlayers(players, lobbyId, hostId) {
  const el = document.getElementById('waitingPlayers');
  if (!players.length) { el.innerHTML = ''; return; }
  el.innerHTML = players.map(p => `
    <div class="player-card">
      <div class="avatar">${esc(p.name[0].toUpperCase())}</div>
      <div class="pname">${esc(p.name)}</div>
      ${p.id === hostId || p.id === state.playerId && state.isHost ? '<div class="host-tag">👑 Host</div>' : ''}
    </div>
  `).join('');
}

function startGame() {
  send({ type: 'start_game' });
}

// ── Game ─────────────────────────────────────────────────
function startRound(msg) {
  state.currentHint = msg.hint;
  state.currentWordLength = msg.wordLength;
  state.answered = false;

  document.getElementById('roundNum').textContent = `${msg.round} / ${msg.maxRounds}`;
  document.getElementById('hintText').textContent = msg.hint;
  document.getElementById('wordLengthText').textContent = `${msg.wordLength} letters`;

  // Blanks
  const blanksEl = document.getElementById('wordBlanks');
  blanksEl.innerHTML = Array(msg.wordLength).fill(0).map((_, i) =>
    `<div class="blank" id="blank_${i}"></div>`
  ).join('');

  // Enable input
  const input = document.getElementById('spellInput');
  input.value = '';
  input.disabled = false;
  input.className = 'spell-input';
  input.focus();
  document.getElementById('submitBtn').disabled = false;

  // Auto-speak
  setTimeout(() => speakHint(), 500);

  // Timer
  startTimer(msg.timeLimit || 30);

  addEvent(`📝 Round ${msg.round} — new word (${msg.wordLength} letters)`, 'ev-info');
}

function updateBlanks(val) {
  const len = state.currentWordLength;
  for (let i = 0; i < len; i++) {
    const b = document.getElementById(`blank_${i}`);
    if (b) b.classList.toggle('filled', i < val.length);
  }
}

function handleSpellKey(e) {
  if (e.key === 'Enter') submitAnswer();
  // block spaces
  if (e.key === ' ') e.preventDefault();
}

function submitAnswer() {
  if (state.answered) return;
  const val = document.getElementById('spellInput').value.trim().toLowerCase();
  if (!val) return;
  state.answered = true;
  document.getElementById('spellInput').disabled = true;
  document.getElementById('submitBtn').disabled = true;
  send({ type: 'submit_answer', answer: val });
}

function showSpellFeedback(correct) {
  const input = document.getElementById('spellInput');
  input.className = 'spell-input ' + (correct ? 'correct' : 'wrong');
  if (!correct) {
    setTimeout(() => { input.className = 'spell-input'; }, 400);
  }
}

function renderGameScores(scores) {
  document.getElementById('gameScores').innerHTML = scores.map((s, i) => `
    <div class="score-row">
      <div class="score-rank ${i===0?'gold':i===1?'silver':i===2?'bronze':''}">${i===0?'🥇':i===1?'🥈':i===2?'🥉':i+1}</div>
      <div class="score-name${s.id===state.playerId?' me':''}">${esc(s.name)}${s.id===state.playerId?' (you)':''}</div>
      <div class="score-pts">${s.score} pts</div>
    </div>
  `).join('');
}

// ── Timer ─────────────────────────────────────────────────
function startTimer(secs) {
  clearTimer();
  state.timerSecs = secs;
  const arc = document.getElementById('timerArc');
  const label = document.getElementById('timerLabel');
  const circumference = 175.9;

  const update = () => {
    label.textContent = state.timerSecs;
    const pct = state.timerSecs / secs;
    arc.style.strokeDashoffset = circumference * (1 - pct);
    arc.style.stroke = pct > 0.5 ? 'var(--accent2)' : pct > 0.25 ? 'var(--accent3)' : 'var(--danger)';
    if (state.timerSecs <= 0) { clearTimer(); return; }
    state.timerSecs--;
  };

  update();
  state.timerInterval = setInterval(update, 1000);
}

function clearTimer() {
  if (state.timerInterval) clearInterval(state.timerInterval);
  state.timerInterval = null;
}

// ── TTS ──────────────────────────────────────────────────
function speakHint() {
  if (!state.currentHint) return;
  const btn = document.getElementById('ttsBtn');
  if ('speechSynthesis' in window) {
    window.speechSynthesis.cancel();
    const utt = new SpeechSynthesisUtterance(state.currentHint);
    utt.rate = 0.85;
    utt.pitch = 1.0;
    utt.volume = 1.0;
    // Prefer English voice
    const voices = window.speechSynthesis.getVoices();
    const eng = voices.find(v => v.lang.startsWith('en')) || voices[0];
    if (eng) utt.voice = eng;
    btn.classList.add('speaking');
    btn.innerHTML = '<span>⏸</span> Speaking…';
    utt.onend = utt.onerror = () => {
      btn.classList.remove('speaking');
      btn.innerHTML = '<span>▶</span> Hear Again';
    };
    window.speechSynthesis.speak(utt);
  } else {
    notify('TTS not supported in this browser', 'error');
  }
}

// ── Game Over ────────────────────────────────────────────
function showGameOver(scores, lb) {
  if (scores && scores.length) {
    document.getElementById('winnerName').textContent = scores[0].name;
    document.getElementById('winnerScore').textContent = `${scores[0].score} pts`;
    document.getElementById('finalScores').innerHTML = scores.map((s, i) => `
      <div class="score-row">
        <div class="score-rank ${i===0?'gold':i===1?'silver':i===2?'bronze':''}">${i===0?'🥇':i===1?'🥈':i===2?'🥉':i+1}</div>
        <div class="score-name${s.id===state.playerId?' me':''}">${esc(s.name)}</div>
        <div class="score-pts">${s.score} pts</div>
      </div>
    `).join('');
  }
  renderLeaderboard(lb || [], 'finalLb');
  showScreen('screen-gameover');
}

function backToLobby() {
  state.lobbyId = null;
  state.isHost = false;
  requestLobbies();
  showScreen('screen-lobby');
}

// ── Leaderboard Render ───────────────────────────────────
function renderLeaderboard(data, targetId) {
  const el = document.getElementById(targetId);
  if (!el) return;
  if (!data || !data.length) {
    el.innerHTML = `<div style="padding:30px;text-align:center;color:var(--muted)">Belum ada skor!</div>`;
    return;
  }
  el.innerHTML = data.map((e, i) => `
    <div class="lb-row">
      <div class="score-rank ${i===0?'gold':i===1?'silver':i===2?'bronze':''}">${i===0?'🥇':i===1?'🥈':i===2?'🥉':i+1}</div>
      <div style="font-weight:600">${esc(e.username || e.name || '?')}</div>
      <div style="font-family:'Space Mono',monospace;font-weight:700">${e.score ?? e.totalScore ?? 0}</div>
      <div style="color:var(--muted)">${e.games_played ?? e.gamesPlayed ?? 0}</div>
    </div>
  `).join('');
}

// ── Events Log ───────────────────────────────────────────
function addEvent(text, cls) {
  const log = document.getElementById('eventsLog');
  if (!log) return;
  const div = document.createElement('div');
  div.className = cls || '';
  div.textContent = text;
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
}
function clearEvents() {
  const log = document.getElementById('eventsLog');
  if (log) log.innerHTML = '';
}

// ── Notifications ────────────────────────────────────────
function notify(msg, type = 'info') {
  const container = document.getElementById('notif');
  const el = document.createElement('div');
  el.className = `notif-item ${type}`;
  el.textContent = msg;
  container.appendChild(el);
  setTimeout(() => el.remove(), 3500);
}

// ── Utils ────────────────────────────────────────────────
function esc(str) {
  return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// ── SOLO STATE & FUNCTIONS ───────────────────────────────
const soloState = {
  active: false,
  difficulty: 'easy',
  rounds: 5,
  score: 0,
  lives: 3,
  streak: 0,
  bestStreak: 0,
  correctCount: 0,
  currentHint: null,
  currentWordLength: 0,
  answered: false,
  timerInterval: null,
  timerSecs: 30
};

function selectSoloDiff(diff, el) {
  document.querySelectorAll('#soloModeCards .mode-card').forEach(c => c.classList.remove('selected'));
  el.classList.add('selected');
  soloState.difficulty = diff;
}

function startSolo() {
  const rounds = parseInt(document.getElementById('soloRounds').value);
  soloState.rounds = rounds;
  send({ type: 'solo_start', difficulty: soloState.difficulty, rounds });
}

function soloStartRound(msg) {
  soloState.active = true;
  soloState.currentHint = msg.hint;
  soloState.currentWordLength = msg.wordLength;
  soloState.answered = false;
  soloState.lives = msg.lives;
  soloState.score = msg.score;
  soloState.streak = msg.streak;

  document.getElementById('soloRoundNum').textContent =
    msg.maxRounds >= 999 ? `${msg.round} / ∞` : `${msg.round} / ${msg.maxRounds}`;
  // Kata/hint TIDAK ditampilkan — hanya didengar via TTS

  const input = document.getElementById('soloSpellInput');
  input.value = '';
  input.disabled = false;
  input.className = 'spell-input';
  input.focus();
  document.getElementById('soloSubmitBtn').disabled = false;

  // Reset tombol dengarkan
  const btn = document.getElementById('soloTtsBtn');
  btn.classList.remove('speaking');
  btn.innerHTML = '<span>▶</span> Dengarkan';

  soloSyncStats();
  setTimeout(() => soloSpeakHint(), 400);
  startSoloTimer(msg.timeLimit || 30);
  addSoloEvent(`📝 Ronde ${msg.round} — dengarkan kata dan eja!`, 'ev-info');
}

function soloSyncStats() {
  document.getElementById('soloScore').textContent = soloState.score;
  document.getElementById('soloCorrectCount').textContent = soloState.correctCount;
  document.getElementById('soloBestStreak').textContent = soloState.bestStreak;
  const livesEl = document.getElementById('soloLives');
  livesEl.innerHTML = ['❤️','❤️','❤️'].map((h, i) =>
    `<span style="opacity:${i < soloState.lives ? 1 : 0.2}">${h}</span>`
  ).join('');
  const streakEl = document.getElementById('soloStreak');
  streakEl.textContent = `🔥 ${soloState.streak} streak`;
  if (soloState.streak >= 3) streakEl.classList.add('hot');
  else streakEl.classList.remove('hot');
}

function updateSoloBlanks(val) {
  const len = soloState.currentWordLength;
  for (let i = 0; i < len; i++) {
    const b = document.getElementById(`sblank_${i}`);
    if (b) b.classList.toggle('filled', i < val.length);
  }
}

function handleSoloKey(e) {
  if (e.key === 'Enter') submitSoloAnswer();
  if (e.key === ' ') e.preventDefault();
}

function submitSoloAnswer() {
  if (soloState.answered) return;
  const val = document.getElementById('soloSpellInput').value.trim().toLowerCase();
  if (!val) return;
  send({ type: 'solo_answer', answer: val });
}

function skipSoloWord() {
  if (soloState.answered) return;
  clearSoloTimer();
  document.getElementById('soloSpellInput').disabled = true;
  document.getElementById('soloSubmitBtn').disabled = true;
  soloState.answered = true;
  send({ type: 'solo_skip' });
}

function quitSolo() {
  if (!confirm('Keluar dari sesi ini? Skor kamu akan disimpan.')) return;
  // Langsung matikan TTS dan tandai tidak aktif agar setTimeout TTS tidak jalan
  soloState.active = false;
  soloState.currentHint = null;
  if ('speechSynthesis' in window) window.speechSynthesis.cancel();
  clearSoloTimer();
  send({ type: 'solo_quit' });
}

function showSoloFeedback(correct) {
  const input = document.getElementById('soloSpellInput');
  input.className = 'spell-input ' + (correct ? 'correct' : 'wrong');
  if (!correct) setTimeout(() => { input.className = 'spell-input'; }, 400);
}

function soloSpeakHint() {
  if (!soloState.currentHint || !soloState.active) return;
  const btn = document.getElementById('soloTtsBtn');
  if ('speechSynthesis' in window) {
    window.speechSynthesis.cancel();
    const utt = new SpeechSynthesisUtterance(soloState.currentHint);
    utt.rate = 0.85; utt.pitch = 1.0; utt.volume = 1.0;
    const voices = window.speechSynthesis.getVoices();
    const eng = voices.find(v => v.lang.startsWith('en')) || voices[0];
    if (eng) utt.voice = eng;
    btn.classList.add('speaking');
    btn.innerHTML = '<span>⏸</span> Memutar…';
    utt.onend = utt.onerror = () => {
      btn.classList.remove('speaking');
      btn.innerHTML = '<span>▶</span> Dengarkan';
    };
    window.speechSynthesis.speak(utt);
  }
}

function startSoloTimer(secs) {
  clearSoloTimer();
  soloState.timerSecs = secs;
  const arc = document.getElementById('soloTimerArc');
  const label = document.getElementById('soloTimerLabel');
  const circumference = 175.9;
  const update = () => {
    label.textContent = soloState.timerSecs;
    const pct = soloState.timerSecs / secs;
    arc.style.strokeDashoffset = circumference * (1 - pct);
    arc.style.stroke = pct > 0.5 ? 'var(--accent2)' : pct > 0.25 ? 'var(--accent3)' : 'var(--danger)';
    if (soloState.timerSecs <= 0) {
      clearSoloTimer();
      if (!soloState.answered) {
        addSoloEvent(`⏱️ Waktu habis!`, 'ev-info');
        skipSoloWord();
      }
      return;
    }
    soloState.timerSecs--;
  };
  update();
  soloState.timerInterval = setInterval(update, 1000);
}

function clearSoloTimer() {
  if (soloState.timerInterval) clearInterval(soloState.timerInterval);
  soloState.timerInterval = null;
}

function showSoloOver(msg) {
  const titles = [
    { min: 80, text: '🏆 Spelling Master!', sub: 'Incredible accuracy!' },
    { min: 60, text: '🌟 Great Job!', sub: 'You\'re getting better!' },
    { min: 40, text: '👍 Not Bad!', sub: 'Keep practicing!' },
    { min: 0,  text: '💪 Keep Going!', sub: 'Practice makes perfect!' }
  ];
  const accuracy = msg.totalRounds > 0 ? Math.round((msg.correctCount / msg.totalRounds) * 100) : 0;
  const t = titles.find(x => accuracy >= x.min) || titles[titles.length - 1];
  document.getElementById('soloOverTitle').textContent = t.text;
  document.getElementById('soloOverSub').textContent = t.sub + ` (${accuracy}% accuracy)`;
  document.getElementById('soloFinalScore').textContent = msg.score;
  document.getElementById('soloFinalCorrect').textContent = `${msg.correctCount}/${msg.totalRounds}`;
  document.getElementById('soloFinalStreak').textContent = msg.bestStreak;
  const m = Math.floor(msg.duration / 60);
  const s = msg.duration % 60;
  document.getElementById('soloFinalTime').textContent = m > 0 ? `${m}m${s}s` : `${s}s`;
  renderLeaderboard(msg.leaderboard || [], 'soloFinalLb');
  showScreen('screen-solo-over');
}

function playAgainSolo() {
  showScreen('screen-lobby');
  switchTab('tab-solo');
}

function backToLobbyFromSolo() {
  showScreen('screen-lobby');
  switchTab('tab-browse');
}

function addSoloEvent(text, cls) {
  const log = document.getElementById('soloEventsLog');
  if (!log) return;
  const div = document.createElement('div');
  div.className = cls || '';
  div.textContent = text;
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
}
function clearSoloEvents() {
  const log = document.getElementById('soloEventsLog');
  if (log) log.innerHTML = '';
}

// ── TRANSLATION STATE & FUNCTIONS ────────────────────────
const transState = {
  active: false,
  score: 0,
  lives: 3,
  streak: 0,
  bestStreak: 0,
  correctCount: 0,
  answered: false,
  timerInterval: null,
  timerSecs: 45,
  sourceLang: 'English',
  targetLang: 'Indonesian'
};

function startTrans() {
  const source = document.getElementById('transSource').value.trim() || 'English';
  const target = document.getElementById('transTarget').value.trim() || 'Indonesian';
  const minW = parseInt(document.getElementById('transMinWords').value);
  const maxW = parseInt(document.getElementById('transMaxWords').value);
  const rounds = parseInt(document.getElementById('transRounds').value);
  if (minW > maxW) { notify('Min kata tidak boleh lebih besar dari Max kata', 'error'); return; }
  transState.sourceLang = source;
  transState.targetLang = target;
  send({ type: 'trans_start', sourceLang: source, targetLang: target, minWords: minW, maxWords: maxW, rounds });
}

function transStartRound(msg) {
  transState.active = true;
  transState.answered = false;
  transState.lives = msg.lives;
  transState.score = msg.score;
  transState.streak = msg.streak;
  transState.sourceLang = msg.sourceLang;
  transState.targetLang = msg.targetLang;

  document.getElementById('transRoundNum').textContent =
    `${msg.round} / ${msg.maxRounds}`;
  document.getElementById('transFromLabel').textContent =
    `🌐 Terjemahkan dari ${msg.sourceLang} → ${msg.targetLang}`;
  document.getElementById('transPhraseText').textContent = msg.phrase;
  document.getElementById('transChecking').style.display = 'none';

  const input = document.getElementById('transAnswerInput');
  input.value = '';
  input.disabled = false;
  input.style.borderColor = '';
  input.focus();
  document.getElementById('transSubmitBtn').disabled = false;

  transSyncStats();
  startTransTimer(msg.timeLimit || 45);
  addTransEvent(`📝 Ronde ${msg.round}: "${msg.phrase}"`, 'ev-info');
}

function transSyncStats() {
  document.getElementById('transScore').textContent = transState.score;
  document.getElementById('transCorrectCount').textContent = transState.correctCount;
  document.getElementById('transBestStreak').textContent = transState.bestStreak;
  const livesEl = document.getElementById('transLives');
  livesEl.innerHTML = ['❤️','❤️','❤️'].map((h, i) =>
    `<span style="opacity:${i < transState.lives ? 1 : 0.2}">${h}</span>`
  ).join('');
  const streakEl = document.getElementById('transStreak');
  streakEl.textContent = `🔥 ${transState.streak} streak`;
}

function handleTransKey(e) {
  if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) submitTransAnswer();
}

function submitTransAnswer() {
  if (transState.answered) return;
  const val = document.getElementById('transAnswerInput').value.trim();
  if (!val) { notify('Ketik terjemahan dulu', 'error'); return; }
  transState.answered = true;
  document.getElementById('transAnswerInput').disabled = true;
  send({ type: 'trans_answer', answer: val });
}

function skipTransWord() {
  if (transState.answered) return;
  clearTransTimer();
  document.getElementById('transAnswerInput').disabled = true;
  document.getElementById('transSubmitBtn').disabled = true;
  transState.answered = true;
  send({ type: 'trans_skip' });
}

function quitTrans() {
  if (!confirm('Keluar? Skor kamu akan disimpan.')) return;
  transState.active = false;
  clearTransTimer();
  send({ type: 'trans_quit' });
}

function showTransFeedback(correct) {
  const input = document.getElementById('transAnswerInput');
  input.style.borderColor = correct ? 'var(--success)' : 'var(--danger)';
  if (!correct) setTimeout(() => { input.style.borderColor = ''; }, 600);
}

function startTransTimer(secs) {
  clearTransTimer();
  transState.timerSecs = secs;
  const arc = document.getElementById('transTimerArc');
  const label = document.getElementById('transTimerLabel');
  const circumference = 175.9;
  const update = () => {
    label.textContent = transState.timerSecs;
    const pct = transState.timerSecs / secs;
    arc.style.strokeDashoffset = circumference * (1 - pct);
    arc.style.stroke = pct > 0.5 ? 'var(--accent2)' : pct > 0.25 ? 'var(--accent3)' : 'var(--danger)';
    if (transState.timerSecs <= 0) {
      clearTransTimer();
      if (!transState.answered) {
        addTransEvent('⏱️ Waktu habis!', 'ev-info');
        skipTransWord();
      }
      return;
    }
    transState.timerSecs--;
  };
  update();
  transState.timerInterval = setInterval(update, 1000);
}

function clearTransTimer() {
  if (transState.timerInterval) clearInterval(transState.timerInterval);
  transState.timerInterval = null;
}

function showTransOver(msg) {
  const accuracy = msg.totalRounds > 0 ? Math.round((msg.correctCount / msg.totalRounds) * 100) : 0;
  const titles = [
    { min: 80, text: '🏆 Penerjemah Andal!', sub: 'Akurasi luar biasa!' },
    { min: 60, text: '🌟 Bagus Sekali!', sub: 'Terus berlatih!' },
    { min: 40, text: '👍 Lumayan!', sub: 'Kamu semakin mahir!' },
    { min: 0,  text: '💪 Terus Semangat!', sub: 'Latihan itu kunci!' }
  ];
  const t = titles.find(x => accuracy >= x.min) || titles[titles.length - 1];
  document.getElementById('transOverTitle').textContent = t.text;
  document.getElementById('transOverSub').textContent = t.sub + ` (${accuracy}% akurasi)`;
  document.getElementById('transFinalScore').textContent = msg.score;
  document.getElementById('transFinalCorrect').textContent = `${msg.correctCount}/${msg.totalRounds}`;
  document.getElementById('transFinalStreak').textContent = msg.bestStreak;
  const m = Math.floor(msg.duration / 60), s2 = msg.duration % 60;
  document.getElementById('transFinalTime').textContent = m > 0 ? `${m}m${s2}s` : `${s2}s`;
  renderLeaderboard(msg.leaderboard || [], 'transFinalLb');
  showScreen('screen-trans-over');
}

function playAgainTrans() {
  showScreen('screen-lobby');
  switchTab('tab-trans');
}

function backToLobbyFromTrans() {
  showScreen('screen-lobby');
  switchTab('tab-browse');
}

function addTransEvent(text, cls) {
  const log = document.getElementById('transEventsLog');
  if (!log) return;
  const div = document.createElement('div');
  div.className = cls || '';
  div.textContent = text;
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
}

function clearTransEvents() {
  const log = document.getElementById('transEventsLog');
  if (log) log.innerHTML = '';
}

// ── Init ─────────────────────────────────────────────────
window.addEventListener('hashchange', handleHashChange);
window.addEventListener('resize', () => {
  const nav = document.getElementById('floatingNav');
  if (state.playerName) {
    nav.style.display = window.innerWidth >= 768 ? 'flex' : 'none';
    document.getElementById('hamburgerBtn').style.display = window.innerWidth < 768 ? 'flex' : 'none';
  }
});

connect();

// Pre-load TTS voices
if ('speechSynthesis' in window) {
  window.speechSynthesis.onvoiceschanged = () => window.speechSynthesis.getVoices();
}
</script>
</body>
</html>
HTMLEOF

  chown -R www-data:www-data "$WWW_DIR"
  chmod -R 755 "$WWW_DIR"
  log "Frontend created at $WWW_DIR"
}

# ============================================================
# STEP 6: INSTALL BACKEND DEPS & PM2
# ============================================================
install_and_run() {
  section "Installing Dependencies & Starting Backend"

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  cd "$INSTALL_DIR/backend"
  info "Installing backend npm packages (including SQLite native build)..."
  # Ensure build tools for better-sqlite3
  apt-get install -y build-essential python3 2>/dev/null || true
  npm install --omit=dev 2>&1 | tail -5

  mkdir -p "$INSTALL_DIR/logs"

  # PM2 ecosystem
  cat > "$INSTALL_DIR/ecosystem.config.js" << EOF
module.exports = {
  apps: [{
    name: 'spellduel-backend',
    script: 'src/index.js',
    cwd: '$INSTALL_DIR/backend',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '256M',
    env: { NODE_ENV: 'production', PORT: 3001 },
    error_file: '$INSTALL_DIR/logs/error.log',
    out_file: '$INSTALL_DIR/logs/out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss'
  }]
};
EOF

  # Kill any process on 3001
  fuser -k 3001/tcp 2>/dev/null || true
  sleep 1

  pm2 delete spellduel-backend 2>/dev/null || true
  cd "$INSTALL_DIR"
  pm2 start ecosystem.config.js
  pm2 save --force

  # PM2 startup
  pm2 startup systemd -u root --hp /root 2>/dev/null | tail -1 | bash 2>/dev/null || true

  sleep 3

  if pm2 list | grep -q "spellduel-backend"; then
    log "SpellDuel backend running via PM2"
  else
    warn "PM2 may have issues. Check: pm2 logs spellduel-backend"
  fi
}

# ============================================================
# STEP 7: CONFIGURE NGINX
# ============================================================
setup_nginx() {
  section "Configuring Nginx for SpellDuel"

  SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "_")

  # Disable default
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  # Remove old spellduel config if exists
  rm -f /etc/nginx/sites-enabled/spellduel 2>/dev/null || true
  rm -f /etc/nginx/sites-available/spellduel 2>/dev/null || true

  cat > /etc/nginx/sites-available/spellduel << NGINXEOF
# SpellDuel - AI Spelling Game
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_IP _;

    access_log /var/log/nginx/spellduel-access.log;
    error_log  /var/log/nginx/spellduel-error.log warn;

    client_max_body_size 5M;

    root $WWW_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass         http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
    }

    location /ws {
        proxy_pass         http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;
        proxy_set_header   Host       \$host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location ~* \.(js|css|png|ico|svg|woff2)$ {
        expires 7d;
        add_header Cache-Control "public";
        try_files \$uri =404;
    }
}
NGINXEOF

  ln -sf /etc/nginx/sites-available/spellduel /etc/nginx/sites-enabled/spellduel
  nginx -t && log "Nginx config valid" || error "Nginx config invalid"

  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
    log "Nginx reloaded"
  else
    systemctl start nginx && systemctl enable nginx
    log "Nginx started"
  fi
}

# ============================================================
# STEP 8: VERIFY
# ============================================================
verify() {
  section "Verifying Deployment"

  sleep 2

  nginx_ok=false
  backend_ok=false
  frontend_ok=false
  proxy_ok=false

  systemctl is-active --quiet nginx && { log "Nginx: running ✓"; nginx_ok=true; } || warn "Nginx: not running"
  pm2 list 2>/dev/null | grep -q "spellduel-backend" && { log "Backend PM2: running ✓"; backend_ok=true; } || warn "Backend: not in PM2"

  if curl -sf http://localhost:3001/health &>/dev/null; then
    log "Backend API :3001: responding ✓"
    backend_ok=true
  else
    warn "Backend API :3001: not responding yet"
  fi

  [ -f "$WWW_DIR/index.html" ] && { log "Frontend: index.html found ✓"; frontend_ok=true; } || warn "Frontend: missing"

  if curl -sf http://localhost/api/health &>/dev/null; then
    log "Nginx→Backend proxy: working ✓"
    proxy_ok=true
  else
    warn "Nginx proxy: not responding yet (may still be starting)"
  fi

  SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "your-server-ip")

  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║       🎯 SPELLDUEL DEPLOYED SUCCESSFULLY!        ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  🌐 Open game:  ${CYAN}http://${SERVER_IP}${NC}"
  echo -e "  🔧 API health: ${CYAN}http://${SERVER_IP}/api/health${NC}"
  echo ""
  echo -e "  📋 Commands:"
  echo -e "     ${CYAN}pm2 logs spellduel-backend${NC}    — backend logs"
  echo -e "     ${CYAN}pm2 restart spellduel-backend${NC} — restart backend"
  echo -e "     ${CYAN}pm2 status${NC}                    — process status"
  echo -e "     ${CYAN}nginx -t${NC}                      — test nginx config"
  echo ""
}

# ============================================================
# MAIN
# ============================================================
main() {
  print_banner
  [[ $EUID -ne 0 ]] && error "Run as root: sudo bash install_spellduel.sh"

  cleanup_old
  check_prereqs
  create_structure
  create_backend
  create_frontend
  install_and_run
  setup_nginx
  verify
}

main "$@"
