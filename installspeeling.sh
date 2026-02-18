#!/bin/bash
# ============================================================
# LangComp - Language Competition Platform Auto Installer
# Ubuntu 22.04 | Node.js + Express | PostgreSQL | Redis
# Ollama | Whisper | TTS | Nginx | PM2
# ============================================================

set -e

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
hdr()  { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLUE}  $1${NC}"; echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}\n"; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Jalankan sebagai root: sudo ./install.sh"

APP_DIR="/app"
NODE_ENV="production"
DB_NAME="langcomp"
DB_USER="langcomp_user"
DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
JWT_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
JWT_REFRESH=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
REDIS_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
PORT=3000

# ════════════════════════════════════════════════════════════
hdr "STEP 1 — Update & Upgrade OS"
# ════════════════════════════════════════════════════════════
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y
log "OS updated"

# ════════════════════════════════════════════════════════════
hdr "STEP 2 — Install System Dependencies"
# ════════════════════════════════════════════════════════════
apt-get install -y \
  curl git build-essential ffmpeg nginx \
  postgresql postgresql-contrib redis-server \
  python3 python3-pip python3-venv \
  ufw software-properties-common \
  openssl htop net-tools \
  libssl-dev libffi-dev
log "System packages installed"

# ── Node.js LTS ──────────────────────────────────────────────
if ! command -v node &>/dev/null; then
  info "Installing Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
log "Node.js $(node -v) installed"

# ── PM2 ─────────────────────────────────────────────────────
npm install -g pm2 2>/dev/null
log "PM2 installed"

# ════════════════════════════════════════════════════════════
hdr "STEP 3 — Install Ollama"
# ════════════════════════════════════════════════════════════
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
  sleep 3
fi
systemctl enable ollama 2>/dev/null || true
systemctl start ollama 2>/dev/null || true
sleep 5
log "Ollama installed"

# ════════════════════════════════════════════════════════════
hdr "STEP 4 — Pull AI Models"
# ════════════════════════════════════════════════════════════
info "Pulling mistral:7b-instruct (this may take a while)..."
ollama pull mistral:7b-instruct || warn "mistral pull failed, will retry later"

info "Pulling phi3:mini (optional)..."
ollama pull phi3:mini || warn "phi3:mini pull failed, skipping"
log "AI models ready"

# ════════════════════════════════════════════════════════════
hdr "STEP 5 — Install Whisper"
# ════════════════════════════════════════════════════════════
python3 -m venv /opt/whisper-env
/opt/whisper-env/bin/pip install --upgrade pip wheel setuptools
/opt/whisper-env/bin/pip install openai-whisper
# Pre-download base model
/opt/whisper-env/bin/python -c "import whisper; whisper.load_model('base')" &
WHISPER_PID=$!
log "Whisper installing in background (PID: $WHISPER_PID)"

# ════════════════════════════════════════════════════════════
hdr "STEP 6 — Install TTS (Kokoro/edge-tts)"
# ════════════════════════════════════════════════════════════
/opt/whisper-env/bin/pip install edge-tts 2>/dev/null || warn "edge-tts install failed"
/opt/whisper-env/bin/pip install kokoro 2>/dev/null || warn "kokoro not available, using edge-tts"
log "TTS installed"

# ════════════════════════════════════════════════════════════
hdr "STEP 7 — Generate Project Structure"
# ════════════════════════════════════════════════════════════
mkdir -p $APP_DIR/{client,server/{controllers,routes,middlewares,services,models,utils},models,audio/{cache,temp},scripts,logs}
cd $APP_DIR
log "Project directories created at $APP_DIR"

# ════════════════════════════════════════════════════════════
hdr "STEP 8 — Generate Backend Code"
# ════════════════════════════════════════════════════════════

# ── package.json ─────────────────────────────────────────────
cat > $APP_DIR/package.json << 'PKGJSON'
{
  "name": "langcomp",
  "version": "1.0.0",
  "description": "Language Competition Platform",
  "main": "server/index.js",
  "scripts": {
    "start": "node server/index.js",
    "dev": "nodemon server/index.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "socket.io": "^4.7.2",
    "pg": "^8.11.3",
    "redis": "^4.6.10",
    "bcryptjs": "^2.4.3",
    "jsonwebtoken": "^9.0.2",
    "helmet": "^7.1.0",
    "cors": "^2.8.5",
    "express-rate-limit": "^7.1.5",
    "joi": "^17.11.0",
    "xss": "^1.0.14",
    "multer": "^1.4.5-lts.1",
    "dotenv": "^16.3.1",
    "uuid": "^9.0.0",
    "axios": "^1.6.2",
    "compression": "^1.7.4",
    "morgan": "^1.10.0",
    "bull": "^4.12.0",
    "node-cron": "^3.0.3",
    "winston": "^3.11.0",
    "express-validator": "^7.0.1",
    "csurf": "^1.11.0",
    "cookie-parser": "^1.4.6",
    "express-session": "^1.17.3",
    "connect-redis": "^7.1.0",
    "fastest-levenshtein": "^1.0.16"
  },
  "devDependencies": {
    "nodemon": "^3.0.2"
  }
}
PKGJSON

# ── server/index.js ───────────────────────────────────────────
cat > $APP_DIR/server/index.js << 'SERVERJS'
require('dotenv').config({ path: require('path').join(__dirname, '../.env') });
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const helmet = require('helmet');
const cors = require('cors');
const compression = require('compression');
const morgan = require('morgan');
const cookieParser = require('cookie-parser');
const rateLimit = require('express-rate-limit');
const path = require('path');
const winston = require('winston');
const { initDB } = require('./models/db');
const { initRedis } = require('./services/redis');
const { setupSocketIO } = require('./services/socket');

// ── Logger ────────────────────────────────────────────────────
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(winston.format.timestamp(), winston.format.json()),
  transports: [
    new winston.transports.File({ filename: path.join(__dirname, '../logs/error.log'), level: 'error' }),
    new winston.transports.File({ filename: path.join(__dirname, '../logs/combined.log') }),
    new winston.transports.Console({ format: winston.format.simple() })
  ]
});
global.logger = logger;

const app = express();
const server = http.createServer(app);

// ── Socket.IO ─────────────────────────────────────────────────
const io = new Server(server, {
  cors: { origin: process.env.CORS_ORIGIN || '*', methods: ['GET','POST'], credentials: true },
  pingTimeout: 60000,
  pingInterval: 25000
});

// ── Security Middleware ───────────────────────────────────────
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", "'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"],
      fontSrc: ["'self'", "https://fonts.gstatic.com"],
      imgSrc: ["'self'", "data:", "blob:"],
      mediaSrc: ["'self'", "blob:"],
      connectSrc: ["'self'", "ws:", "wss:"]
    }
  },
  crossOriginEmbedderPolicy: false
}));

app.disable('x-powered-by');
app.set('trust proxy', 1);

const corsOptions = {
  origin: process.env.CORS_ORIGIN ? process.env.CORS_ORIGIN.split(',') : ['http://localhost:3000'],
  credentials: true,
  methods: ['GET','POST','PUT','DELETE','OPTIONS'],
  allowedHeaders: ['Content-Type','Authorization','X-CSRF-Token']
};
app.use(cors(corsOptions));

// ── Rate Limiting ─────────────────────────────────────────────
const globalLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 300,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests, please try again later.' }
});
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  message: { error: 'Too many auth attempts, please try again later.' }
});

app.use(globalLimiter);
app.use(compression());
app.use(express.json({ limit: '2mb' }));
app.use(express.urlencoded({ extended: true, limit: '2mb' }));
app.use(cookieParser());
app.use(morgan('combined', { stream: { write: m => logger.info(m.trim()) } }));

// ── Static Files ──────────────────────────────────────────────
app.use(express.static(path.join(__dirname, '../client'), {
  dotfiles: 'deny',
  index: false,
  setHeaders: (res) => {
    res.set('X-Content-Type-Options', 'nosniff');
  }
}));

// ── API Routes ────────────────────────────────────────────────
app.use('/api/auth', authLimiter, require('./routes/auth'));
app.use('/api/rooms', require('./routes/rooms'));
app.use('/api/game', require('./routes/game'));
app.use('/api/leaderboard', require('./routes/leaderboard'));
app.use('/api/profile', require('./routes/profile'));
app.use('/api/translate', require('./routes/translate'));
app.use('/api/tts', require('./routes/tts'));

// ── SPA Catch-all ─────────────────────────────────────────────
app.get('*', (req, res) => {
  if (req.path.startsWith('/api')) return res.status(404).json({ error: 'Not found' });
  res.sendFile(path.join(__dirname, '../client/index.html'));
});

// ── Error Handler ─────────────────────────────────────────────
app.use((err, req, res, next) => {
  logger.error(err.stack);
  res.status(err.status || 500).json({ error: process.env.NODE_ENV === 'production' ? 'Internal server error' : err.message });
});

// ── Boot ──────────────────────────────────────────────────────
async function boot() {
  try {
    await initDB();
    logger.info('Database connected');
    await initRedis();
    logger.info('Redis connected');
    setupSocketIO(io);
    const PORT = process.env.PORT || 3000;
    server.listen(PORT, () => logger.info(`LangComp server running on port ${PORT}`));
  } catch (err) {
    logger.error('Boot error:', err);
    process.exit(1);
  }
}
boot();
SERVERJS

# ── server/models/db.js ───────────────────────────────────────
cat > $APP_DIR/server/models/db.js << 'DBJS'
const { Pool } = require('pg');
const path = require('path');

let pool;

async function initDB() {
  pool = new Pool({
    host: process.env.DB_HOST || 'localhost',
    port: parseInt(process.env.DB_PORT) || 5432,
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASS,
    max: 20,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 2000
  });
  await pool.query('SELECT 1');
  await runMigrations();
}

async function runMigrations() {
  await pool.query(`
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

    CREATE TABLE IF NOT EXISTS users (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      username VARCHAR(50) UNIQUE NOT NULL,
      email VARCHAR(255) UNIQUE NOT NULL,
      password_hash VARCHAR(255) NOT NULL,
      avatar VARCHAR(255) DEFAULT NULL,
      role VARCHAR(20) DEFAULT 'user',
      is_active BOOLEAN DEFAULT true,
      login_attempts INTEGER DEFAULT 0,
      locked_until TIMESTAMP DEFAULT NULL,
      last_seen TIMESTAMP DEFAULT NOW(),
      created_at TIMESTAMP DEFAULT NOW(),
      updated_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS rooms (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      code VARCHAR(8) UNIQUE NOT NULL,
      name VARCHAR(100) NOT NULL,
      host_id UUID REFERENCES users(id) ON DELETE CASCADE,
      mode VARCHAR(20) NOT NULL DEFAULT 'spelling',
      level VARCHAR(20) DEFAULT 'medium',
      is_public BOOLEAN DEFAULT true,
      max_players INTEGER DEFAULT 4,
      match_duration INTEGER DEFAULT 300,
      answer_time INTEGER DEFAULT 30,
      max_words INTEGER DEFAULT 10,
      status VARCHAR(20) DEFAULT 'waiting',
      started_at TIMESTAMP DEFAULT NULL,
      finished_at TIMESTAMP DEFAULT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS room_players (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      room_id UUID REFERENCES rooms(id) ON DELETE CASCADE,
      user_id UUID REFERENCES users(id) ON DELETE CASCADE,
      joined_at TIMESTAMP DEFAULT NOW(),
      UNIQUE(room_id, user_id)
    );

    CREATE TABLE IF NOT EXISTS matches (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      room_id UUID REFERENCES rooms(id) ON DELETE SET NULL,
      mode VARCHAR(20) NOT NULL,
      level VARCHAR(20) DEFAULT 'medium',
      is_solo BOOLEAN DEFAULT false,
      created_at TIMESTAMP DEFAULT NOW(),
      finished_at TIMESTAMP DEFAULT NULL
    );

    CREATE TABLE IF NOT EXISTS match_results (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      match_id UUID REFERENCES matches(id) ON DELETE CASCADE,
      user_id UUID REFERENCES users(id) ON DELETE CASCADE,
      score INTEGER DEFAULT 0,
      correct_count INTEGER DEFAULT 0,
      almost_count INTEGER DEFAULT 0,
      wrong_count INTEGER DEFAULT 0,
      avg_response_time FLOAT DEFAULT 0,
      rank INTEGER DEFAULT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS speaking_results (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      match_id UUID REFERENCES matches(id) ON DELETE CASCADE,
      user_id UUID REFERENCES users(id) ON DELETE CASCADE,
      original_text TEXT,
      transcription TEXT,
      accuracy FLOAT DEFAULT 0,
      word_accuracy FLOAT DEFAULT 0,
      response_time FLOAT DEFAULT 0,
      score INTEGER DEFAULT 0,
      rank INTEGER DEFAULT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS global_leaderboard_spelling (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE,
      total_score INTEGER DEFAULT 0,
      total_correct INTEGER DEFAULT 0,
      total_matches INTEGER DEFAULT 0,
      total_wins INTEGER DEFAULT 0,
      accuracy FLOAT DEFAULT 0,
      avg_response_time FLOAT DEFAULT 0,
      updated_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS global_leaderboard_speaking (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE,
      total_score INTEGER DEFAULT 0,
      avg_accuracy FLOAT DEFAULT 0,
      total_tests INTEGER DEFAULT 0,
      total_wins INTEGER DEFAULT 0,
      highest_score INTEGER DEFAULT 0,
      updated_at TIMESTAMP DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS translator_usage_stats (
      id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
      user_id UUID REFERENCES users(id) ON DELETE CASCADE,
      source_lang VARCHAR(10),
      target_lang VARCHAR(10),
      word_count INTEGER DEFAULT 0,
      created_at TIMESTAMP DEFAULT NOW()
    );

    CREATE INDEX IF NOT EXISTS idx_rooms_status ON rooms(status);
    CREATE INDEX IF NOT EXISTS idx_rooms_code ON rooms(code);
    CREATE INDEX IF NOT EXISTS idx_match_results_match ON match_results(match_id);
    CREATE INDEX IF NOT EXISTS idx_match_results_user ON match_results(user_id);
    CREATE INDEX IF NOT EXISTS idx_speaking_results_user ON speaking_results(user_id);
  `);
}

function query(text, params) {
  return pool.query(text, params);
}

module.exports = { initDB, query, getPool: () => pool };
DBJS

# ── server/services/redis.js ──────────────────────────────────
cat > $APP_DIR/server/services/redis.js << 'REDISJS'
const { createClient } = require('redis');
let client;

async function initRedis() {
  client = createClient({
    url: process.env.REDIS_URL || `redis://:${process.env.REDIS_PASS}@localhost:6379`,
    socket: { reconnectStrategy: (retries) => Math.min(retries * 50, 2000) }
  });
  client.on('error', err => logger.error('Redis error:', err));
  await client.connect();
}

const redis = {
  get: (k) => client.get(k),
  set: (k, v, opts) => client.set(k, typeof v === 'object' ? JSON.stringify(v) : v, opts),
  del: (k) => client.del(k),
  expire: (k, s) => client.expire(k, s),
  incr: (k) => client.incr(k),
  zadd: (k, s, m) => client.zAdd(k, [{ score: s, value: m }]),
  zrevrange: (k, s, e, opts) => client.zRangeWithScores(k, s, e, { REV: true }),
  hset: (k, f, v) => client.hSet(k, f, v),
  hget: (k, f) => client.hGet(k, f),
  hgetall: (k) => client.hGetAll(k),
  publish: (ch, msg) => client.publish(ch, typeof msg === 'object' ? JSON.stringify(msg) : msg),
  subscribe: (ch, cb) => {
    const sub = client.duplicate();
    sub.connect().then(() => sub.subscribe(ch, cb));
    return sub;
  },
  keys: (pattern) => client.keys(pattern),
  ttl: (k) => client.ttl(k),
  setex: (k, s, v) => client.setEx(k, s, typeof v === 'object' ? JSON.stringify(v) : v),
  getClient: () => client
};

module.exports = { initRedis, redis };
REDISJS

# ── server/services/socket.js ─────────────────────────────────
cat > $APP_DIR/server/services/socket.js << 'SOCKETJS'
const jwt = require('jsonwebtoken');
const { redis } = require('./redis');
const { query } = require('../models/db');
const { levenshtein } = require('../utils/levenshtein');

function setupSocketIO(io) {
  // Auth middleware
  io.use(async (socket, next) => {
    try {
      const token = socket.handshake.auth.token || socket.handshake.headers.authorization?.split(' ')[1];
      if (!token) return next(new Error('Unauthorized'));
      const decoded = jwt.verify(token, process.env.JWT_SECRET);
      const session = await redis.get(`session:${decoded.userId}`);
      if (!session) return next(new Error('Session expired'));
      socket.userId = decoded.userId;
      socket.username = decoded.username;
      next();
    } catch (err) {
      next(new Error('Invalid token'));
    }
  });

  io.on('connection', (socket) => {
    logger.info(`Socket connected: ${socket.userId}`);

    // Heartbeat
    const heartbeat = setInterval(async () => {
      await redis.setex(`online:${socket.userId}`, 30, '1');
    }, 15000);

    // ── Room Events ───────────────────────────────────────────
    socket.on('room:join', async ({ roomId }) => {
      socket.join(roomId);
      await redis.hset(`room:${roomId}:players`, socket.userId, JSON.stringify({ username: socket.username, score: 0, ready: false }));
      const players = await redis.hgetall(`room:${roomId}:players`);
      io.to(roomId).emit('room:players', { players: Object.fromEntries(Object.entries(players).map(([k,v]) => [k, JSON.parse(v)])) });
    });

    socket.on('room:leave', async ({ roomId }) => {
      socket.leave(roomId);
      await redis.getClient().hDel(`room:${roomId}:players`, socket.userId);
      const players = await redis.hgetall(`room:${roomId}:players`);
      io.to(roomId).emit('room:players', { players: Object.fromEntries(Object.entries(players || {}).map(([k,v]) => [k, JSON.parse(v)])) });
    });

    socket.on('room:ready', async ({ roomId }) => {
      const data = await redis.hget(`room:${roomId}:players`, socket.userId);
      if (data) {
        const p = JSON.parse(data);
        p.ready = true;
        await redis.hset(`room:${roomId}:players`, socket.userId, JSON.stringify(p));
      }
      const players = await redis.hgetall(`room:${roomId}:players`);
      const parsed = Object.fromEntries(Object.entries(players || {}).map(([k,v]) => [k, JSON.parse(v)]));
      io.to(roomId).emit('room:players', { players: parsed });
      const allReady = Object.values(parsed).every(p => p.ready);
      if (allReady && Object.keys(parsed).length >= 2) {
        io.to(roomId).emit('game:start', { roomId });
      }
    });

    socket.on('room:start', async ({ roomId }) => {
      io.to(roomId).emit('game:start', { roomId });
    });

    // ── Spelling Events ───────────────────────────────────────
    socket.on('spelling:answer', async ({ roomId, answer, word, responseTime }) => {
      const dist = levenshtein(answer.toLowerCase().trim(), word.toLowerCase().trim());
      let result, points;
      if (dist === 0)      { result = 'correct'; points = 10 + (responseTime < 3 ? 3 : 0); }
      else if (dist <= 2)  { result = 'almost';  points = 5; }
      else                 { result = 'wrong';   points = 0; }

      // Update score in Redis
      const data = await redis.hget(`room:${roomId}:players`, socket.userId);
      if (data) {
        const p = JSON.parse(data);
        p.score = (p.score || 0) + points;
        if (result === 'correct') p.correct = (p.correct || 0) + 1;
        if (result === 'almost')  p.almost  = (p.almost  || 0) + 1;
        if (result === 'wrong')   p.wrong   = (p.wrong   || 0) + 1;
        await redis.hset(`room:${roomId}:players`, socket.userId, JSON.stringify(p));
      }

      socket.emit('spelling:result', { result, points, dist });

      // Broadcast scores
      const players = await redis.hgetall(`room:${roomId}:players`);
      io.to(roomId).emit('game:scores', { players: Object.fromEntries(Object.entries(players || {}).map(([k,v]) => [k, JSON.parse(v)])) });
    });

    // ── Speaking Events ───────────────────────────────────────
    socket.on('speaking:score', async ({ roomId, accuracy, score }) => {
      const data = await redis.hget(`room:${roomId}:players`, socket.userId);
      if (data) {
        const p = JSON.parse(data);
        p.score = (p.score || 0) + score;
        p.accuracy = accuracy;
        await redis.hset(`room:${roomId}:players`, socket.userId, JSON.stringify(p));
      }
      const players = await redis.hgetall(`room:${roomId}:players`);
      io.to(roomId).emit('game:scores', { players: Object.fromEntries(Object.entries(players || {}).map(([k,v]) => [k, JSON.parse(v)])) });
    });

    // ── Game End ──────────────────────────────────────────────
    socket.on('game:end', async ({ roomId }) => {
      const players = await redis.hgetall(`room:${roomId}:players`);
      if (players) {
        const sorted = Object.entries(players)
          .map(([id, v]) => ({ id, ...JSON.parse(v) }))
          .sort((a, b) => b.score - a.score);
        io.to(roomId).emit('game:finished', { results: sorted });
      }
    });

    // ── Visibility / Heartbeat ────────────────────────────────
    socket.on('tab:hidden', ({ roomId }) => {
      if (roomId) socket.emit('game:warning', { msg: 'Kamu meninggalkan tab!' });
    });

    socket.on('tab:away', ({ roomId }) => {
      if (roomId) {
        io.to(roomId).emit('player:disconnected', { userId: socket.userId, username: socket.username });
        socket.emit('game:ended', { reason: 'Tab meninggal >5 detik' });
      }
    });

    // ── Chat ──────────────────────────────────────────────────
    socket.on('chat:message', ({ roomId, message }) => {
      if (!message || message.length > 200) return;
      const xss = require('xss');
      io.to(roomId).emit('chat:message', {
        userId: socket.userId,
        username: socket.username,
        message: xss(message),
        time: new Date().toISOString()
      });
    });

    socket.on('disconnect', () => {
      clearInterval(heartbeat);
      logger.info(`Socket disconnected: ${socket.userId}`);
    });
  });
}

module.exports = { setupSocketIO };
SOCKETJS

# ── server/utils/levenshtein.js ───────────────────────────────
cat > $APP_DIR/server/utils/levenshtein.js << 'LEVJS'
const { distance } = require('fastest-levenshtein');

function levenshtein(a, b) {
  return distance(a, b);
}

function wordAccuracy(original, transcription) {
  const origWords = original.toLowerCase().split(/\s+/).filter(Boolean);
  const transWords = transcription.toLowerCase().split(/\s+/).filter(Boolean);
  if (!origWords.length) return 0;
  let correct = 0;
  origWords.forEach((w, i) => { if (transWords[i] === w) correct++; });
  return Math.round((correct / origWords.length) * 100);
}

function similarity(a, b) {
  const maxLen = Math.max(a.length, b.length);
  if (!maxLen) return 100;
  return Math.round(((maxLen - levenshtein(a, b)) / maxLen) * 100);
}

module.exports = { levenshtein, wordAccuracy, similarity };
LEVJS

# ── server/middlewares/auth.js ────────────────────────────────
cat > $APP_DIR/server/middlewares/auth.js << 'AUTHMW'
const jwt = require('jsonwebtoken');
const { redis } = require('../services/redis');

async function authenticate(req, res, next) {
  try {
    const token = req.headers.authorization?.split(' ')[1] || req.cookies?.token;
    if (!token) return res.status(401).json({ error: 'No token provided' });
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    const session = await redis.get(`session:${decoded.userId}`);
    if (!session) return res.status(401).json({ error: 'Session expired' });
    // Refresh session on activity
    await redis.expire(`session:${decoded.userId}`, parseInt(process.env.SESSION_TTL) || 86400);
    req.user = decoded;
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Invalid token' });
  }
}

module.exports = { authenticate };
AUTHMW

# ── server/middlewares/validate.js ───────────────────────────
cat > $APP_DIR/server/middlewares/validate.js << 'VALIDMW'
const Joi = require('joi');
const xss = require('xss');

function sanitize(obj) {
  if (typeof obj === 'string') return xss(obj.trim());
  if (typeof obj === 'object' && obj !== null) {
    return Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, sanitize(v)]));
  }
  return obj;
}

function validate(schema) {
  return (req, res, next) => {
    req.body = sanitize(req.body);
    req.query = sanitize(req.query);
    const { error } = schema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ error: error.details.map(d => d.message).join(', ') });
    next();
  };
}

const schemas = {
  register: Joi.object({
    username: Joi.string().alphanum().min(3).max(30).required(),
    email: Joi.string().email().required(),
    password: Joi.string().min(8).max(128).required()
  }),
  login: Joi.object({
    email: Joi.string().email().required(),
    password: Joi.string().required()
  }),
  createRoom: Joi.object({
    name: Joi.string().min(3).max(50).required(),
    mode: Joi.string().valid('spelling','speaking','translator').required(),
    level: Joi.string().valid('easy','medium','hard').default('medium'),
    is_public: Joi.boolean().default(true),
    max_players: Joi.number().integer().min(2).max(10).default(4),
    match_duration: Joi.number().integer().min(60).max(3600).default(300),
    answer_time: Joi.number().integer().min(10).max(120).default(30),
    max_words: Joi.number().integer().min(1).max(50).default(10)
  })
};

module.exports = { validate, schemas, sanitize };
VALIDMW

# ── server/controllers/auth.controller.js ────────────────────
cat > $APP_DIR/server/controllers/auth.controller.js << 'AUTHCTRL'
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const { query } = require('../models/db');
const { redis } = require('../services/redis');

const MAX_ATTEMPTS = 5;
const LOCK_DURATION = 15 * 60; // 15 min
const SESSION_TTL = parseInt(process.env.SESSION_TTL) || 86400;

exports.register = async (req, res) => {
  try {
    const { username, email, password } = req.body;
    const exists = await query('SELECT id FROM users WHERE email=$1 OR username=$2', [email, username]);
    if (exists.rows.length) return res.status(409).json({ error: 'Email atau username sudah digunakan' });
    const hash = await bcrypt.hash(password, 12);
    const result = await query(
      'INSERT INTO users(username,email,password_hash) VALUES($1,$2,$3) RETURNING id,username,email',
      [username, email, hash]
    );
    const user = result.rows[0];
    await query('INSERT INTO global_leaderboard_spelling(user_id) VALUES($1) ON CONFLICT DO NOTHING', [user.id]);
    await query('INSERT INTO global_leaderboard_speaking(user_id) VALUES($1) ON CONFLICT DO NOTHING', [user.id]);
    res.status(201).json({ message: 'Registrasi berhasil', user: { id: user.id, username: user.username, email: user.email } });
  } catch (err) {
    logger.error('Register error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

exports.login = async (req, res) => {
  try {
    const { email, password } = req.body;
    const result = await query('SELECT * FROM users WHERE email=$1', [email]);
    const user = result.rows[0];
    if (!user) return res.status(401).json({ error: 'Email atau password salah' });

    // Check lock
    if (user.locked_until && new Date(user.locked_until) > new Date()) {
      const remaining = Math.ceil((new Date(user.locked_until) - new Date()) / 60000);
      return res.status(423).json({ error: `Akun terkunci. Coba lagi dalam ${remaining} menit.` });
    }

    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) {
      const attempts = user.login_attempts + 1;
      if (attempts >= MAX_ATTEMPTS) {
        const lockUntil = new Date(Date.now() + LOCK_DURATION * 1000);
        await query('UPDATE users SET login_attempts=$1, locked_until=$2 WHERE id=$3', [attempts, lockUntil, user.id]);
        return res.status(423).json({ error: 'Akun terkunci 15 menit karena terlalu banyak percobaan login.' });
      }
      await query('UPDATE users SET login_attempts=$1 WHERE id=$2', [attempts, user.id]);
      return res.status(401).json({ error: `Password salah. ${MAX_ATTEMPTS - attempts} percobaan tersisa.` });
    }

    await query('UPDATE users SET login_attempts=0, locked_until=NULL, last_seen=NOW() WHERE id=$1', [user.id]);

    const token = jwt.sign(
      { userId: user.id, username: user.username, role: user.role },
      process.env.JWT_SECRET,
      { expiresIn: process.env.JWT_EXPIRY || '24h' }
    );
    await redis.setex(`session:${user.id}`, SESSION_TTL, token);

    res.cookie('token', token, { httpOnly: true, secure: process.env.NODE_ENV === 'production', sameSite: 'strict', maxAge: SESSION_TTL * 1000 });
    res.json({ token, user: { id: user.id, username: user.username, email: user.email, role: user.role } });
  } catch (err) {
    logger.error('Login error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

exports.logout = async (req, res) => {
  try {
    await redis.del(`session:${req.user.userId}`);
    res.clearCookie('token');
    res.json({ message: 'Logged out' });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
};

exports.me = async (req, res) => {
  try {
    const result = await query('SELECT id,username,email,avatar,role,created_at,last_seen FROM users WHERE id=$1', [req.user.userId]);
    if (!result.rows.length) return res.status(404).json({ error: 'User not found' });
    res.json({ user: result.rows[0] });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
};
AUTHCTRL

# ── server/controllers/game.controller.js ────────────────────
cat > $APP_DIR/server/controllers/game.controller.js << 'GAMECTRL'
const axios = require('axios');
const { query } = require('../models/db');
const { redis } = require('../services/redis');
const { similarity, wordAccuracy } = require('../utils/levenshtein');
const path = require('path');
const fs = require('fs');
const { execSync, spawn } = require('child_process');
const { v4: uuidv4 } = require('uuid');

const OLLAMA_URL = process.env.OLLAMA_URL || 'http://localhost:11434';
const OLLAMA_MODEL = process.env.OLLAMA_MODEL || 'mistral:7b-instruct';
const MAX_CONCURRENT_AI = parseInt(process.env.MAX_CONCURRENT_AI) || 2;
const MAX_CONCURRENT_TTS = parseInt(process.env.MAX_CONCURRENT_TTS) || 2;
let aiInProgress = 0;
let ttsInProgress = 0;

async function ollamaGenerate(prompt, retries = 2) {
  while (aiInProgress >= MAX_CONCURRENT_AI) {
    await new Promise(r => setTimeout(r, 500));
  }
  aiInProgress++;
  try {
    const res = await axios.post(`${OLLAMA_URL}/api/generate`, {
      model: OLLAMA_MODEL,
      prompt,
      stream: false,
      options: { temperature: 0.7, top_p: 0.9, num_predict: 200 }
    }, { timeout: 30000 });
    return res.data.response?.trim() || '';
  } catch (err) {
    if (retries > 0) return ollamaGenerate(prompt, retries - 1);
    throw err;
  } finally {
    aiInProgress--;
  }
}

exports.generateWord = async (req, res) => {
  try {
    const { level = 'medium', count = 1 } = req.query;
    const cacheKey = `words:${level}:${count}`;
    const cached = await redis.get(cacheKey);
    if (cached) return res.json({ words: JSON.parse(cached) });

    const diffMap = { easy: 'simple common English words (4-6 letters)', medium: 'intermediate English words (6-9 letters)', hard: 'advanced vocabulary words (9+ letters)' };
    const prompt = `Generate ${count} ${diffMap[level] || diffMap.medium} for a spelling competition. Return ONLY a JSON array of strings, no explanation. Example: ["apple","banana"]`;
    const raw = await ollamaGenerate(prompt);
    let words;
    try {
      words = JSON.parse(raw.match(/\[.*\]/s)?.[0] || '[]');
    } catch { words = raw.split('\n').filter(w => /^[a-zA-Z]+$/.test(w.trim())).slice(0, count); }
    if (!words.length) words = ['language','competition','knowledge','challenge','practice'];
    await redis.setex(cacheKey, 300, JSON.stringify(words));
    res.json({ words });
  } catch (err) {
    logger.error('generateWord error:', err);
    res.status(500).json({ error: 'Failed to generate word' });
  }
};

exports.generateText = async (req, res) => {
  try {
    const { level = 'sentence', maxWords = 20 } = req.query;
    const levelMap = { word: `a single English word`, sentence: `an English sentence of about ${Math.min(maxWords,15)} words`, paragraph: `an English paragraph of about ${Math.min(maxWords,50)} words` };
    const prompt = `Generate ${levelMap[level] || levelMap.sentence} for a speaking competition. Return ONLY the text, no explanation, no quotes.`;
    const text = await ollamaGenerate(prompt);
    const clean = text.replace(/^["']|["']$/g, '').trim();
    res.json({ text: clean });
  } catch (err) {
    logger.error('generateText error:', err);
    res.status(500).json({ error: 'Failed to generate text' });
  }
};

exports.transcribeAudio = async (req, res) => {
  const audioPath = req.file?.path;
  if (!audioPath) return res.status(400).json({ error: 'No audio file' });
  try {
    const outFile = audioPath.replace(/\.[^.]+$/, '.txt');
    const whisperBin = '/opt/whisper-env/bin/whisper';
    await new Promise((resolve, reject) => {
      const proc = spawn(whisperBin, [audioPath, '--model', 'base', '--output_format', 'txt', '--output_dir', path.dirname(audioPath), '--language', 'en', '--fp16', 'False'], { timeout: 60000 });
      proc.on('close', code => code === 0 ? resolve() : reject(new Error('Whisper failed')));
      proc.on('error', reject);
    });
    const transcription = fs.existsSync(outFile) ? fs.readFileSync(outFile, 'utf8').trim() : '';
    fs.unlinkSync(audioPath);
    if (fs.existsSync(outFile)) fs.unlinkSync(outFile);
    res.json({ transcription });
  } catch (err) {
    logger.error('Transcribe error:', err);
    if (audioPath && fs.existsSync(audioPath)) fs.unlinkSync(audioPath);
    res.status(500).json({ error: 'Transcription failed' });
  }
};

exports.scoreSpeeaking = async (req, res) => {
  try {
    const { original, transcription } = req.body;
    if (!original || !transcription) return res.status(400).json({ error: 'Missing fields' });
    const sim = similarity(original, transcription);
    const wordAcc = wordAccuracy(original, transcription);
    const avg = Math.round((sim + wordAcc) / 2);
    let grade, score;
    if (avg >= 90) { grade = 'correct'; score = 10; }
    else if (avg >= 70) { grade = 'almost'; score = 5; }
    else { grade = 'wrong'; score = 0; }
    res.json({ similarity: sim, wordAccuracy: wordAcc, accuracy: avg, grade, score });
  } catch (err) {
    res.status(500).json({ error: 'Scoring failed' });
  }
};

exports.saveMatchResult = async (req, res) => {
  try {
    const { matchId, score, correctCount, almostCount, wrongCount, avgResponseTime } = req.body;
    await query(
      'INSERT INTO match_results(match_id,user_id,score,correct_count,almost_count,wrong_count,avg_response_time) VALUES($1,$2,$3,$4,$5,$6,$7)',
      [matchId, req.user.userId, score, correctCount, almostCount, wrongCount, avgResponseTime]
    );
    // Update global leaderboard
    await query(`
      INSERT INTO global_leaderboard_spelling(user_id,total_score,total_correct,total_matches,updated_at)
      VALUES($1,$2,$3,1,NOW())
      ON CONFLICT(user_id) DO UPDATE SET
        total_score = global_leaderboard_spelling.total_score + $2,
        total_correct = global_leaderboard_spelling.total_correct + $3,
        total_matches = global_leaderboard_spelling.total_matches + 1,
        updated_at = NOW()
    `, [req.user.userId, score, correctCount]);
    res.json({ message: 'Result saved' });
  } catch (err) {
    logger.error('saveMatchResult error:', err);
    res.status(500).json({ error: 'Failed to save result' });
  }
};

exports.saveSpeakingResult = async (req, res) => {
  try {
    const { matchId, originalText, transcription, accuracy, wordAccuracy, responseTime, score } = req.body;
    await query(
      'INSERT INTO speaking_results(match_id,user_id,original_text,transcription,accuracy,word_accuracy,response_time,score) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
      [matchId, req.user.userId, originalText, transcription, accuracy, wordAccuracy, responseTime, score]
    );
    await query(`
      INSERT INTO global_leaderboard_speaking(user_id,total_score,avg_accuracy,total_tests,highest_score,updated_at)
      VALUES($1,$2,$3,1,$2,NOW())
      ON CONFLICT(user_id) DO UPDATE SET
        total_score = global_leaderboard_speaking.total_score + $2,
        avg_accuracy = (global_leaderboard_speaking.avg_accuracy * global_leaderboard_speaking.total_tests + $3) / (global_leaderboard_speaking.total_tests + 1),
        total_tests = global_leaderboard_speaking.total_tests + 1,
        highest_score = GREATEST(global_leaderboard_speaking.highest_score, $2),
        updated_at = NOW()
    `, [req.user.userId, score, accuracy]);
    res.json({ message: 'Speaking result saved' });
  } catch (err) {
    logger.error('saveSpeakingResult error:', err);
    res.status(500).json({ error: 'Failed to save result' });
  }
};
GAMECTRL

# ── server/controllers/rooms.controller.js ───────────────────
cat > $APP_DIR/server/controllers/rooms.controller.js << 'ROOMCTRL'
const { query } = require('../models/db');
const { v4: uuidv4 } = require('uuid');
const crypto = require('crypto');

function genCode() {
  return crypto.randomBytes(4).toString('hex').toUpperCase();
}

exports.listRooms = async (req, res) => {
  try {
    const result = await query(`
      SELECT r.*, u.username as host_name,
             COUNT(rp.user_id)::int as player_count
      FROM rooms r
      LEFT JOIN users u ON r.host_id = u.id
      LEFT JOIN room_players rp ON r.id = rp.room_id
      WHERE r.is_public=true AND r.status='waiting'
      GROUP BY r.id, u.username
      ORDER BY r.created_at DESC LIMIT 50
    `);
    res.json({ rooms: result.rows });
  } catch (err) {
    logger.error('listRooms error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

exports.createRoom = async (req, res) => {
  try {
    const { name, mode, level, is_public, max_players, match_duration, answer_time, max_words } = req.body;
    let code;
    let tries = 0;
    do {
      code = genCode();
      const exists = await query('SELECT id FROM rooms WHERE code=$1', [code]);
      if (!exists.rows.length) break;
      tries++;
    } while (tries < 10);

    const result = await query(
      `INSERT INTO rooms(code,name,host_id,mode,level,is_public,max_players,match_duration,answer_time,max_words)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *`,
      [code, name, req.user.userId, mode, level, is_public, max_players, match_duration, answer_time, max_words]
    );
    const room = result.rows[0];
    await query('INSERT INTO room_players(room_id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING', [room.id, req.user.userId]);
    res.status(201).json({ room });
  } catch (err) {
    logger.error('createRoom error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

exports.joinRoom = async (req, res) => {
  try {
    const { code } = req.params;
    const result = await query(`
      SELECT r.*, COUNT(rp.user_id)::int as player_count
      FROM rooms r LEFT JOIN room_players rp ON r.id=rp.room_id
      WHERE r.code=$1 GROUP BY r.id
    `, [code.toUpperCase()]);
    const room = result.rows[0];
    if (!room) return res.status(404).json({ error: 'Room tidak ditemukan' });
    if (room.status !== 'waiting') return res.status(400).json({ error: 'Game sudah dimulai' });
    if (room.player_count >= room.max_players) return res.status(400).json({ error: 'Room penuh' });
    await query('INSERT INTO room_players(room_id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING', [room.id, req.user.userId]);
    res.json({ room });
  } catch (err) {
    logger.error('joinRoom error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

exports.getRoom = async (req, res) => {
  try {
    const { id } = req.params;
    const result = await query(`
      SELECT r.*, u.username as host_name FROM rooms r
      LEFT JOIN users u ON r.host_id=u.id WHERE r.id=$1
    `, [id]);
    if (!result.rows.length) return res.status(404).json({ error: 'Room not found' });
    const players = await query(`
      SELECT u.id, u.username, u.avatar FROM room_players rp
      JOIN users u ON rp.user_id=u.id WHERE rp.room_id=$1
    `, [id]);
    res.json({ room: result.rows[0], players: players.rows });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
};

exports.startRoom = async (req, res) => {
  try {
    const { id } = req.params;
    const room = await query('SELECT * FROM rooms WHERE id=$1 AND host_id=$2', [id, req.user.userId]);
    if (!room.rows.length) return res.status(403).json({ error: 'Hanya host yang bisa memulai' });
    await query('UPDATE rooms SET status=\'playing\', started_at=NOW() WHERE id=$1', [id]);
    const match = await query('INSERT INTO matches(room_id,mode,level) VALUES($1,$2,$3) RETURNING id', [id, room.rows[0].mode, room.rows[0].level]);
    res.json({ matchId: match.rows[0].id });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
};
ROOMCTRL

# ── server/controllers/leaderboard.controller.js ─────────────
cat > $APP_DIR/server/controllers/leaderboard.controller.js << 'LBCTRL'
const { query } = require('../models/db');
const { redis } = require('../services/redis');

function dateFilter(period) {
  switch(period) {
    case 'daily':   return `AND updated_at >= NOW() - INTERVAL '1 day'`;
    case 'weekly':  return `AND updated_at >= NOW() - INTERVAL '7 days'`;
    case 'monthly': return `AND updated_at >= NOW() - INTERVAL '30 days'`;
    default: return '';
  }
}

exports.getSpelling = async (req, res) => {
  try {
    const { period = 'alltime', page = 1, limit = 20 } = req.query;
    const offset = (parseInt(page) - 1) * parseInt(limit);
    const filter = dateFilter(period);
    const cacheKey = `lb:spelling:${period}:${page}`;
    const cached = await redis.get(cacheKey);
    if (cached) return res.json(JSON.parse(cached));
    const result = await query(`
      SELECT gls.*, u.username, u.avatar,
             RANK() OVER (ORDER BY gls.total_score DESC) as rank
      FROM global_leaderboard_spelling gls
      JOIN users u ON gls.user_id=u.id
      WHERE true ${filter}
      ORDER BY gls.total_score DESC
      LIMIT $1 OFFSET $2
    `, [parseInt(limit), offset]);
    const data = { leaderboard: result.rows };
    await redis.setex(cacheKey, 60, JSON.stringify(data));
    res.json(data);
  } catch (err) {
    logger.error('getSpelling LB error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

exports.getSpeaking = async (req, res) => {
  try {
    const { period = 'alltime', page = 1, limit = 20 } = req.query;
    const offset = (parseInt(page) - 1) * parseInt(limit);
    const filter = dateFilter(period);
    const cacheKey = `lb:speaking:${period}:${page}`;
    const cached = await redis.get(cacheKey);
    if (cached) return res.json(JSON.parse(cached));
    const result = await query(`
      SELECT gls.*, u.username, u.avatar,
             RANK() OVER (ORDER BY gls.total_score DESC) as rank
      FROM global_leaderboard_speaking gls
      JOIN users u ON gls.user_id=u.id
      WHERE true ${filter}
      ORDER BY gls.total_score DESC
      LIMIT $1 OFFSET $2
    `, [parseInt(limit), offset]);
    const data = { leaderboard: result.rows };
    await redis.setex(cacheKey, 60, JSON.stringify(data));
    res.json(data);
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
};

exports.getMatchResults = async (req, res) => {
  try {
    const { matchId } = req.params;
    const result = await query(`
      SELECT mr.*, u.username, u.avatar,
             RANK() OVER (ORDER BY mr.score DESC) as rank
      FROM match_results mr JOIN users u ON mr.user_id=u.id
      WHERE mr.match_id=$1 ORDER BY mr.score DESC
    `, [matchId]);
    res.json({ results: result.rows });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
};
LBCTRL

# ── server/controllers/translate.controller.js ───────────────
cat > $APP_DIR/server/controllers/translate.controller.js << 'TRANSCTRL'
const axios = require('axios');
const { query } = require('../models/db');
const { redis } = require('../services/redis');

const OLLAMA_URL = process.env.OLLAMA_URL || 'http://localhost:11434';
const OLLAMA_MODEL = process.env.OLLAMA_MODEL || 'mistral:7b-instruct';

exports.translate = async (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');

  const { text, sourceLang, targetLang, maxWords = 100 } = req.body;
  if (!text || !sourceLang || !targetLang) {
    res.write(`data: ${JSON.stringify({ error: 'Missing fields' })}\n\n`);
    return res.end();
  }

  const prompt = `Translate the following ${sourceLang} text to ${targetLang}. Keep the translation under ${maxWords} words. Return ONLY the translation, no explanation:\n\n${text}`;

  try {
    const response = await axios.post(`${OLLAMA_URL}/api/generate`, {
      model: OLLAMA_MODEL, prompt, stream: true,
      options: { temperature: 0.3, num_predict: maxWords * 3 }
    }, { responseType: 'stream', timeout: 60000 });

    let closed = false;
    req.on('close', () => { closed = true; response.data.destroy(); });

    response.data.on('data', chunk => {
      if (closed) return;
      try {
        const lines = chunk.toString().split('\n').filter(Boolean);
        for (const line of lines) {
          const json = JSON.parse(line);
          if (json.response) res.write(`data: ${JSON.stringify({ token: json.response })}\n\n`);
          if (json.done) {
            res.write(`data: ${JSON.stringify({ done: true })}\n\n`);
            res.end();
          }
        }
      } catch {}
    });

    response.data.on('end', () => { if (!closed) res.end(); });

    // Stats
    await query(
      'INSERT INTO translator_usage_stats(user_id,source_lang,target_lang,word_count) VALUES($1,$2,$3,$4)',
      [req.user.userId, sourceLang, targetLang, text.split(/\s+/).length]
    ).catch(() => {});
  } catch (err) {
    logger.error('Translate error:', err);
    res.write(`data: ${JSON.stringify({ error: 'Translation failed' })}\n\n`);
    res.end();
  }
};
TRANSCTRL

# ── server/controllers/tts.controller.js ─────────────────────
cat > $APP_DIR/server/controllers/tts.controller.js << 'TTSCTRL'
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const { redis } = require('../services/redis');
const crypto = require('crypto');

const AUDIO_CACHE = path.join(__dirname, '../../audio/cache');
const AUDIO_TEMP = path.join(__dirname, '../../audio/temp');
let ttsInProgress = 0;
const MAX_TTS = parseInt(process.env.MAX_CONCURRENT_TTS) || 2;

exports.speak = async (req, res) => {
  const { text, lang = 'en', voice = 'en-US-GuyNeural' } = req.query;
  if (!text || text.length > 500) return res.status(400).json({ error: 'Invalid text' });

  const cacheKey = crypto.createHash('md5').update(`${text}:${voice}`).digest('hex');
  const cachePath = path.join(AUDIO_CACHE, `${cacheKey}.mp3`);

  if (fs.existsSync(cachePath)) {
    res.setHeader('Content-Type', 'audio/mpeg');
    return fs.createReadStream(cachePath).pipe(res);
  }

  while (ttsInProgress >= MAX_TTS) {
    await new Promise(r => setTimeout(r, 300));
  }
  ttsInProgress++;

  const tmpPath = path.join(AUDIO_TEMP, `${cacheKey}.mp3`);
  try {
    await new Promise((resolve, reject) => {
      const proc = spawn('/opt/whisper-env/bin/edge-tts', [
        '--voice', voice, '--text', text, '--write-media', tmpPath
      ], { timeout: 30000 });
      proc.on('close', code => code === 0 ? resolve() : reject(new Error('TTS failed')));
      proc.on('error', reject);
    });

    if (fs.existsSync(tmpPath)) {
      fs.copyFileSync(tmpPath, cachePath);
      fs.unlinkSync(tmpPath);
      res.setHeader('Content-Type', 'audio/mpeg');
      fs.createReadStream(cachePath).pipe(res);
    } else {
      res.status(500).json({ error: 'TTS file not created' });
    }
  } catch (err) {
    logger.error('TTS error:', err);
    res.status(500).json({ error: 'TTS failed' });
  } finally {
    ttsInProgress--;
  }
};
TTSCTRL

# ── server/controllers/profile.controller.js ─────────────────
cat > $APP_DIR/server/controllers/profile.controller.js << 'PROFCTRL'
const { query } = require('../models/db');

exports.getProfile = async (req, res) => {
  try {
    const { id } = req.params;
    const userId = id || req.user.userId;
    const user = await query('SELECT id,username,email,avatar,created_at,last_seen FROM users WHERE id=$1', [userId]);
    if (!user.rows.length) return res.status(404).json({ error: 'User not found' });
    const spelling = await query('SELECT * FROM global_leaderboard_spelling WHERE user_id=$1', [userId]);
    const speaking = await query('SELECT * FROM global_leaderboard_speaking WHERE user_id=$1', [userId]);
    const history = await query(`
      SELECT m.mode, m.created_at, mr.score, mr.correct_count, mr.wrong_count
      FROM match_results mr JOIN matches m ON mr.match_id=m.id
      WHERE mr.user_id=$1 ORDER BY m.created_at DESC LIMIT 10
    `, [userId]);
    res.json({ user: user.rows[0], spelling: spelling.rows[0] || {}, speaking: speaking.rows[0] || {}, history: history.rows });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
};

exports.updateProfile = async (req, res) => {
  try {
    const { username } = req.body;
    if (username) {
      const exists = await query('SELECT id FROM users WHERE username=$1 AND id!=$2', [username, req.user.userId]);
      if (exists.rows.length) return res.status(409).json({ error: 'Username sudah digunakan' });
      await query('UPDATE users SET username=$1, updated_at=NOW() WHERE id=$2', [username, req.user.userId]);
    }
    res.json({ message: 'Profile updated' });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
};
PROFCTRL

# ── Routes ────────────────────────────────────────────────────
cat > $APP_DIR/server/routes/auth.js << 'RAUTH'
const router = require('express').Router();
const ctrl = require('../controllers/auth.controller');
const { validate, schemas } = require('../middlewares/validate');
const { authenticate } = require('../middlewares/auth');
router.post('/register', validate(schemas.register), ctrl.register);
router.post('/login', validate(schemas.login), ctrl.login);
router.post('/logout', authenticate, ctrl.logout);
router.get('/me', authenticate, ctrl.me);
module.exports = router;
RAUTH

cat > $APP_DIR/server/routes/rooms.js << 'RROOMS'
const router = require('express').Router();
const ctrl = require('../controllers/rooms.controller');
const { authenticate } = require('../middlewares/auth');
const { validate, schemas } = require('../middlewares/validate');
router.get('/', authenticate, ctrl.listRooms);
router.post('/', authenticate, validate(schemas.createRoom), ctrl.createRoom);
router.get('/:id', authenticate, ctrl.getRoom);
router.get('/join/:code', authenticate, ctrl.joinRoom);
router.post('/:id/start', authenticate, ctrl.startRoom);
module.exports = router;
RROOMS

cat > $APP_DIR/server/routes/game.js << 'RGAME'
const router = require('express').Router();
const ctrl = require('../controllers/game.controller');
const { authenticate } = require('../middlewares/auth');
const multer = require('multer');
const path = require('path');
const storage = multer.diskStorage({
  destination: path.join(__dirname, '../../audio/temp'),
  filename: (req, file, cb) => cb(null, `${Date.now()}-${Math.random().toString(36).slice(2)}.webm`)
});
const upload = multer({ storage, limits: { fileSize: 10 * 1024 * 1024 }, fileFilter: (req, file, cb) => {
  const ok = ['audio/webm','audio/ogg','audio/wav','audio/mp4','audio/mpeg'].includes(file.mimetype);
  cb(ok ? null : new Error('Invalid file type'), ok);
}});
router.get('/word', authenticate, ctrl.generateWord);
router.get('/text', authenticate, ctrl.generateText);
router.post('/transcribe', authenticate, upload.single('audio'), ctrl.transcribeAudio);
router.post('/score/speaking', authenticate, ctrl.scoreSpeeaking);
router.post('/result/spelling', authenticate, ctrl.saveMatchResult);
router.post('/result/speaking', authenticate, ctrl.saveSpeakingResult);
module.exports = router;
RGAME

cat > $APP_DIR/server/routes/leaderboard.js << 'RLB'
const router = require('express').Router();
const ctrl = require('../controllers/leaderboard.controller');
const { authenticate } = require('../middlewares/auth');
router.get('/spelling', authenticate, ctrl.getSpelling);
router.get('/speaking', authenticate, ctrl.getSpeaking);
router.get('/match/:matchId', authenticate, ctrl.getMatchResults);
module.exports = router;
RLB

cat > $APP_DIR/server/routes/translate.js << 'RTRANS'
const router = require('express').Router();
const ctrl = require('../controllers/translate.controller');
const { authenticate } = require('../middlewares/auth');
const rateLimit = require('express-rate-limit');
const limiter = rateLimit({ windowMs: 60*1000, max: 10 });
router.post('/', authenticate, limiter, ctrl.translate);
module.exports = router;
RTRANS

cat > $APP_DIR/server/routes/tts.js << 'RTTS'
const router = require('express').Router();
const ctrl = require('../controllers/tts.controller');
const { authenticate } = require('../middlewares/auth');
const rateLimit = require('express-rate-limit');
const limiter = rateLimit({ windowMs: 60*1000, max: 30 });
router.get('/speak', authenticate, limiter, ctrl.speak);
module.exports = router;
RTTS

cat > $APP_DIR/server/routes/profile.js << 'RPROF'
const router = require('express').Router();
const ctrl = require('../controllers/profile.controller');
const { authenticate } = require('../middlewares/auth');
router.get('/', authenticate, ctrl.getProfile);
router.get('/:id', authenticate, ctrl.getProfile);
router.put('/', authenticate, ctrl.updateProfile);
module.exports = router;
RPROF

log "Backend code generated"

# ════════════════════════════════════════════════════════════
hdr "STEP 8b — Generate Frontend"
# ════════════════════════════════════════════════════════════

cat > $APP_DIR/client/index.html << 'INDEXHTML'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<title>LangComp — Language Competition Platform</title>
<meta name="description" content="Kompetisi bahasa online realtime: Spelling, Speaking, dan Translator">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/css/style.css">
</head>
<body>
<div id="app">
  <div id="loading-screen">
    <div class="loader-logo">LC</div>
    <div class="loader-bar"><div class="loader-fill"></div></div>
    <p>Memuat LangComp...</p>
  </div>
  <nav id="navbar" class="hidden">
    <div class="nav-brand" onclick="navigate('/')">⚡ LangComp</div>
    <div class="nav-links">
      <a href="#" onclick="navigate('/lobby')">Lobby</a>
      <a href="#" onclick="navigate('/leaderboard')">Leaderboard</a>
      <a href="#" onclick="navigate('/translate')">Translator</a>
    </div>
    <div class="nav-user">
      <span id="nav-username" onclick="navigate('/profile')" style="cursor:pointer"></span>
      <button class="btn-sm" onclick="logout()">Keluar</button>
    </div>
  </nav>
  <main id="view"></main>
</div>
<script src="/socket.io/socket.io.js"></script>
<script src="/js/app.js"></script>
</body>
</html>
INDEXHTML

mkdir -p $APP_DIR/client/{css,js}

# ── CSS ───────────────────────────────────────────────────────
cat > $APP_DIR/client/css/style.css << 'STYLECSS'
:root{--bg:#0a0b0f;--bg2:#12141a;--bg3:#1a1d27;--border:#2a2d3a;--accent:#6c63ff;--accent2:#ff6584;--green:#00e676;--yellow:#ffd600;--red:#ff1744;--text:#e2e8f0;--text2:#8892a4;--radius:12px;--shadow:0 4px 24px rgba(0,0,0,.4)}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',sans-serif;background:var(--bg);color:var(--text);min-height:100vh;overflow-x:hidden}
#loading-screen{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;gap:20px}
.loader-logo{font-size:48px;font-weight:800;background:linear-gradient(135deg,var(--accent),var(--accent2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;animation:pulse 1.5s ease-in-out infinite}
.loader-bar{width:200px;height:4px;background:var(--bg3);border-radius:2px;overflow:hidden}
.loader-fill{height:100%;background:linear-gradient(90deg,var(--accent),var(--accent2));animation:load 1.5s ease-in-out infinite}
@keyframes load{0%{width:0}100%{width:100%}}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}
@keyframes fadeIn{from{opacity:0;transform:translateY(20px)}to{opacity:1;transform:translateY(0)}}
@keyframes glow{0%,100%{box-shadow:0 0 5px var(--accent)}50%{box-shadow:0 0 20px var(--accent),0 0 40px var(--accent)}}
@keyframes countGlow{0%,100%{text-shadow:0 0 10px var(--accent)}50%{text-shadow:0 0 30px var(--accent),0 0 60px var(--accent)}}
@keyframes wave{0%{transform:scaleY(1)}50%{transform:scaleY(2)}100%{transform:scaleY(1)}}
@keyframes slideIn{from{transform:translateX(-20px);opacity:0}to{transform:translateX(0);opacity:1}}
@keyframes rankUp{from{background:rgba(108,99,255,.3)}to{background:transparent}}

#navbar{display:flex;align-items:center;justify-content:space-between;padding:16px 32px;background:rgba(10,11,15,.95);backdrop-filter:blur(12px);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:100}
#navbar.hidden{display:none}
.nav-brand{font-size:22px;font-weight:800;cursor:pointer;background:linear-gradient(135deg,var(--accent),var(--accent2));-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.nav-links{display:flex;gap:24px}.nav-links a{color:var(--text2);text-decoration:none;font-weight:500;transition:.2s}.nav-links a:hover{color:var(--text)}
.nav-user{display:flex;align-items:center;gap:12px}
.hidden{display:none!important}
main{min-height:calc(100vh - 65px);padding:32px;animation:fadeIn .4s ease}
.page{animation:fadeIn .4s ease}
.container{max-width:1100px;margin:0 auto}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);padding:28px;margin-bottom:20px}
.card-sm{background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);padding:16px}
h1{font-size:2.4rem;font-weight:800;margin-bottom:8px}
h2{font-size:1.6rem;font-weight:700;margin-bottom:16px}
h3{font-size:1.1rem;font-weight:600;margin-bottom:8px}
p{color:var(--text2);line-height:1.6}
.gradient-text{background:linear-gradient(135deg,var(--accent),var(--accent2));-webkit-background-clip:text;-webkit-text-fill-color:transparent}

/* Buttons */
.btn{display:inline-flex;align-items:center;gap:8px;padding:12px 24px;border-radius:8px;border:none;font-weight:600;cursor:pointer;transition:.2s;font-size:1rem}
.btn-primary{background:linear-gradient(135deg,var(--accent),#8b5cf6);color:#fff}.btn-primary:hover{opacity:.9;transform:translateY(-1px)}
.btn-danger{background:linear-gradient(135deg,var(--red),#ff5252);color:#fff}
.btn-success{background:linear-gradient(135deg,var(--green),#00bcd4);color:#000}
.btn-outline{background:transparent;border:2px solid var(--accent);color:var(--accent)}.btn-outline:hover{background:var(--accent);color:#fff}
.btn-ghost{background:var(--bg3);color:var(--text);border:1px solid var(--border)}.btn-ghost:hover{border-color:var(--accent)}
.btn-sm{padding:8px 16px;font-size:.875rem;border-radius:6px;border:1px solid var(--border);background:var(--bg3);color:var(--text);cursor:pointer}
.btn:disabled{opacity:.4;cursor:not-allowed;transform:none!important}
.btn-block{width:100%;justify-content:center}

/* Forms */
.form-group{margin-bottom:20px}
label{display:block;margin-bottom:6px;font-weight:500;font-size:.9rem;color:var(--text2)}
input,select,textarea{width:100%;padding:12px 16px;background:var(--bg3);border:1px solid var(--border);border-radius:8px;color:var(--text);font-size:1rem;font-family:inherit;transition:.2s}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px rgba(108,99,255,.15)}
input::placeholder{color:var(--text2)}
.form-row{display:grid;grid-template-columns:1fr 1fr;gap:16px}
select option{background:var(--bg2)}

/* Grid */
.grid-2{display:grid;grid-template-columns:1fr 1fr;gap:20px}
.grid-3{display:grid;grid-template-columns:repeat(3,1fr);gap:20px}
.grid-4{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}
@media(max-width:768px){.grid-2,.grid-3,.grid-4{grid-template-columns:1fr}.form-row{grid-template-columns:1fr}}

/* Alerts */
.alert{padding:12px 16px;border-radius:8px;font-size:.9rem;margin-bottom:12px}
.alert-error{background:rgba(255,23,68,.1);border:1px solid rgba(255,23,68,.3);color:#ff5252}
.alert-success{background:rgba(0,230,118,.1);border:1px solid rgba(0,230,118,.3);color:var(--green)}
.alert-info{background:rgba(108,99,255,.1);border:1px solid rgba(108,99,255,.3);color:var(--accent)}

/* Badge */
.badge{display:inline-flex;align-items:center;padding:4px 10px;border-radius:100px;font-size:.75rem;font-weight:600}
.badge-green{background:rgba(0,230,118,.15);color:var(--green);border:1px solid rgba(0,230,118,.3)}
.badge-yellow{background:rgba(255,214,0,.15);color:var(--yellow);border:1px solid rgba(255,214,0,.3)}
.badge-red{background:rgba(255,23,68,.15);color:var(--red);border:1px solid rgba(255,23,68,.3)}
.badge-blue{background:rgba(108,99,255,.15);color:var(--accent);border:1px solid rgba(108,99,255,.3)}

/* Hero */
.hero{text-align:center;padding:80px 20px;max-width:700px;margin:0 auto}
.hero h1{font-size:3.5rem;margin-bottom:16px;line-height:1.2}
.hero p{font-size:1.2rem;margin-bottom:32px}
.hero-btns{display:flex;gap:16px;justify-content:center;flex-wrap:wrap}
.features{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:20px;margin-top:60px}
.feature-card{background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);padding:28px;text-align:center;transition:.3s}
.feature-card:hover{border-color:var(--accent);transform:translateY(-4px)}
.feature-icon{font-size:40px;margin-bottom:16px}

/* Auth */
.auth-container{max-width:420px;margin:40px auto}
.auth-logo{text-align:center;font-size:28px;font-weight:800;margin-bottom:32px}
.auth-footer{text-align:center;margin-top:20px;color:var(--text2)}
.auth-footer a{color:var(--accent);cursor:pointer;text-decoration:none}

/* Countdown */
.countdown{font-size:80px;font-weight:800;text-align:center;animation:countGlow 1s ease-in-out infinite;font-family:'JetBrains Mono',monospace}
.countdown.urgent{color:var(--red)!important;animation:glow 0.5s ease-in-out infinite}

/* Game Area */
.game-area{max-width:700px;margin:0 auto}
.game-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px;padding:16px 20px;background:var(--bg2);border-radius:var(--radius);border:1px solid var(--border)}
.score-display{font-size:2rem;font-weight:800;font-family:'JetBrains Mono',monospace}
.word-display{font-size:2rem;font-weight:700;text-align:center;padding:40px;background:var(--bg2);border-radius:var(--radius);border:2px solid var(--border);margin:20px 0;letter-spacing:4px;font-family:'JetBrains Mono',monospace;animation:fadeIn .3s ease}
.answer-input{font-size:1.5rem;text-align:center;font-family:'JetBrains Mono',monospace;letter-spacing:2px}
.answer-input.correct{border-color:var(--green)!important;box-shadow:0 0 20px rgba(0,230,118,.3)!important}
.answer-input.almost{border-color:var(--yellow)!important;box-shadow:0 0 20px rgba(255,214,0,.3)!important}
.answer-input.wrong{border-color:var(--red)!important;box-shadow:0 0 20px rgba(255,23,68,.3)!important}
.result-feedback{text-align:center;font-size:1.2rem;font-weight:700;padding:12px;border-radius:8px;margin:12px 0}
.result-feedback.correct{background:rgba(0,230,118,.1);color:var(--green)}
.result-feedback.almost{background:rgba(255,214,0,.1);color:var(--yellow)}
.result-feedback.wrong{background:rgba(255,23,68,.1);color:var(--red)}
.progress-bar{height:6px;background:var(--bg3);border-radius:3px;overflow:hidden;margin-bottom:20px}
.progress-fill{height:100%;background:linear-gradient(90deg,var(--accent),var(--accent2));transition:width .3s}
.timer-ring{position:relative;width:80px;height:80px}
.timer-ring svg{transform:rotate(-90deg)}
.timer-ring circle{fill:none;stroke:var(--bg3);stroke-width:6}
.timer-ring .ring-progress{stroke:var(--accent);stroke-linecap:round;transition:stroke-dashoffset .1s linear}
.timer-text{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:1.2rem;font-weight:700;font-family:'JetBrains Mono',monospace}

/* Waveform */
.waveform{display:flex;align-items:center;justify-content:center;gap:4px;height:60px;margin:20px 0}
.wave-bar{width:4px;background:var(--accent);border-radius:2px;animation:wave 1s ease-in-out infinite}
.wave-bar:nth-child(2){animation-delay:.1s}.wave-bar:nth-child(3){animation-delay:.2s}.wave-bar:nth-child(4){animation-delay:.3s}.wave-bar:nth-child(5){animation-delay:.4s}.wave-bar:nth-child(6){animation-delay:.3s}.wave-bar:nth-child(7){animation-delay:.2s}.wave-bar:nth-child(8){animation-delay:.1s}
.waveform.inactive .wave-bar{animation:none;height:4px}
.record-btn{width:80px;height:80px;border-radius:50%;border:none;cursor:pointer;font-size:32px;display:flex;align-items:center;justify-content:center;margin:0 auto;transition:.2s;background:var(--bg3);border:3px solid var(--border)}
.record-btn.recording{background:rgba(255,23,68,.15);border-color:var(--red);animation:glow 1s ease-in-out infinite}
.record-btn:hover{transform:scale(1.05)}
.transcript-display{background:var(--bg3);border-radius:8px;padding:16px;min-height:60px;font-family:'JetBrains Mono',monospace;font-size:.95rem;line-height:1.6;white-space:pre-wrap}
.word-correct{color:var(--green)}.word-almost{color:var(--yellow)}.word-wrong{color:var(--red);text-decoration:underline}

/* Leaderboard */
.lb-table{width:100%;border-collapse:collapse}
.lb-table th{text-align:left;padding:12px 16px;color:var(--text2);font-size:.85rem;font-weight:500;border-bottom:1px solid var(--border)}
.lb-table td{padding:14px 16px;border-bottom:1px solid rgba(42,45,58,.5)}
.lb-table tr:hover td{background:rgba(108,99,255,.05)}
.lb-table tr.me td{background:rgba(108,99,255,.08)}
.rank-1{color:#ffd700;font-weight:800}.rank-2{color:#c0c0c0;font-weight:700}.rank-3{color:#cd7f32;font-weight:700}
.lb-row-enter{animation:rankUp .5s ease}
.filter-tabs{display:flex;gap:8px;margin-bottom:24px;background:var(--bg2);padding:6px;border-radius:10px;border:1px solid var(--border)}
.filter-tab{flex:1;text-align:center;padding:8px 16px;border-radius:8px;cursor:pointer;font-size:.875rem;font-weight:500;transition:.2s;color:var(--text2)}
.filter-tab.active{background:var(--accent);color:#fff}

/* Lobby */
.room-card{background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);padding:20px;transition:.2s;cursor:pointer}
.room-card:hover{border-color:var(--accent);transform:translateY(-2px)}
.room-meta{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0}
.room-players{color:var(--text2);font-size:.875rem;margin-top:8px}
.rooms-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}

/* Multiplayer Scores */
.scores-panel{background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);padding:16px;margin-left:20px;min-width:220px}
.game-layout{display:flex;gap:20px}
.game-main{flex:1}
.score-item{display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid var(--border)}
.score-item:last-child{border-bottom:none}
.score-value{font-family:'JetBrains Mono',monospace;font-weight:700;font-size:1.2rem}

/* Chat */
.chat-panel{background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);padding:12px;max-height:200px;overflow-y:auto;margin-top:12px}
.chat-msg{font-size:.85rem;padding:4px 0;animation:slideIn .2s ease}
.chat-msg strong{color:var(--accent)}
.chat-input-row{display:flex;gap:8px;margin-top:8px}
.chat-input-row input{flex:1;padding:8px 12px;font-size:.875rem}

/* Modal */
.modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,.7);display:flex;align-items:center;justify-content:center;z-index:1000;backdrop-filter:blur(4px)}
.modal{background:var(--bg2);border:1px solid var(--border);border-radius:var(--radius);padding:32px;max-width:480px;width:90%;animation:fadeIn .3s ease}
.modal h2{margin-bottom:20px}
.modal-btns{display:flex;gap:12px;margin-top:24px;justify-content:flex-end}

/* Translator */
.translate-area{display:grid;grid-template-columns:1fr auto 1fr;gap:16px;align-items:start}
.translate-swap{background:var(--bg3);border:1px solid var(--border);border-radius:50%;width:40px;height:40px;display:flex;align-items:center;justify-content:center;cursor:pointer;margin-top:44px;font-size:18px;transition:.2s}.translate-swap:hover{background:var(--accent);color:#fff}
.translate-box{background:var(--bg3);border:1px solid var(--border);border-radius:8px;padding:16px;min-height:200px;font-size:1rem;width:100%}
.translate-meta{display:flex;justify-content:space-between;align-items:center;margin-top:8px}
.word-counter{font-size:.8rem;color:var(--text2)}
@media(max-width:768px){.translate-area{grid-template-columns:1fr}.translate-swap{margin:0 auto}}

/* Profile */
.avatar-circle{width:80px;height:80px;border-radius:50%;background:linear-gradient(135deg,var(--accent),var(--accent2));display:flex;align-items:center;justify-content:center;font-size:32px;font-weight:700;color:#fff}
.stat-box{text-align:center;padding:20px;background:var(--bg3);border-radius:var(--radius)}
.stat-value{font-size:2rem;font-weight:800;font-family:'JetBrains Mono',monospace}
.stat-label{color:var(--text2);font-size:.85rem}

/* Error Pages */
.error-page{text-align:center;padding:120px 20px}
.error-code{font-size:8rem;font-weight:900;opacity:.15;line-height:1}
.error-msg{font-size:1.5rem;font-weight:700;margin:-20px 0 16px}

/* Scrollbar */
::-webkit-scrollbar{width:6px}::-webkit-scrollbar-track{background:var(--bg)}::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}

/* Tooltip */
[data-tooltip]{position:relative}[data-tooltip]::after{content:attr(data-tooltip);position:absolute;bottom:110%;left:50%;transform:translateX(-50%);background:var(--bg3);border:1px solid var(--border);padding:6px 10px;border-radius:6px;font-size:.75rem;white-space:nowrap;opacity:0;pointer-events:none;transition:.2s}[data-tooltip]:hover::after{opacity:1}
STYLECSS

# ── JavaScript App ────────────────────────────────────────────
cat > $APP_DIR/client/js/app.js << 'APPJS'
// ── State ─────────────────────────────────────────────────────
const App = {
  token: localStorage.getItem('token'),
  user: JSON.parse(localStorage.getItem('user') || 'null'),
  socket: null,
  currentRoom: null,
  currentMatch: null,
  tabHiddenAt: null,
  tabHiddenTimer: null,
};

// ── Helpers ───────────────────────────────────────────────────
const $ = id => document.getElementById(id);
const view = () => $('view');
const api = async (method, path, body, isForm=false) => {
  const opts = { method, headers: { 'Authorization': `Bearer ${App.token}` } };
  if (body && !isForm) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
  if (body && isForm) { opts.body = body; }
  const res = await fetch(`/api${path}`, opts);
  if (res.status === 401) { logout(); return; }
  return res;
};
const html = (s) => { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; };
const toast = (msg, type='info') => {
  const t = document.createElement('div');
  t.className = `alert alert-${type}`;
  t.style.cssText = 'position:fixed;bottom:20px;right:20px;z-index:9999;min-width:250px;animation:fadeIn .3s ease';
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3500);
};

// ── Router ────────────────────────────────────────────────────
const routes = {};
function navigate(path, data={}) {
  history.pushState({ path, data }, '', path);
  render(path, data);
}
window.addEventListener('popstate', e => {
  if (e.state) render(e.state.path, e.state.data || {});
});

function render(path, data={}) {
  const parts = path.split('/').filter(Boolean);
  const base = '/' + (parts[0] || '');
  const id = parts[1];
  const fn = routes[base] || routes['/404'];
  view().innerHTML = '';
  if (fn) fn(data, id);
}

function requireAuth(fn) {
  return (data, id) => {
    if (!App.token || !App.user) { navigate('/login'); return; }
    fn(data, id);
  };
}

// ── Auth ──────────────────────────────────────────────────────
function logout() {
  api('POST', '/auth/logout').catch(() => {});
  localStorage.removeItem('token');
  localStorage.removeItem('user');
  App.token = null; App.user = null;
  if (App.socket) { App.socket.disconnect(); App.socket = null; }
  $('navbar').classList.add('hidden');
  navigate('/login');
}

function initSocket() {
  if (App.socket) return;
  App.socket = io({ auth: { token: App.token }, transports: ['websocket','polling'] });
  App.socket.on('connect_error', err => { if (err.message === 'Unauthorized' || err.message === 'Invalid token') logout(); });
  App.socket.on('game:warning', ({ msg }) => toast(msg, 'error'));
  App.socket.on('game:ended', ({ reason }) => { toast(reason, 'error'); setTimeout(() => navigate('/lobby'), 2000); });
}

function setupVisibilityAPI(roomId) {
  document.addEventListener('visibilitychange', function handler() {
    if (document.hidden) {
      App.tabHiddenAt = Date.now();
      if (App.socket) App.socket.emit('tab:hidden', { roomId });
      App.tabHiddenTimer = setTimeout(() => {
        if (App.socket) App.socket.emit('tab:away', { roomId });
        document.removeEventListener('visibilitychange', handler);
      }, 5000);
    } else {
      if (App.tabHiddenTimer) clearTimeout(App.tabHiddenTimer);
    }
  });
}

// ════════════════════════════════════════════════════════════
// PAGES
// ════════════════════════════════════════════════════════════

// ── Landing ───────────────────────────────────────────────────
routes['/'] = () => {
  $('navbar').classList.add('hidden');
  view().innerHTML = `
  <div class="container">
    <div class="hero">
      <h1>⚡ <span class="gradient-text">LangComp</span></h1>
      <p>Platform kompetisi bahasa realtime — Spelling, Speaking, dan Translator berbasis AI</p>
      <div class="hero-btns">
        <button class="btn btn-primary" onclick="navigate('/register')">Mulai Gratis</button>
        <button class="btn btn-outline" onclick="navigate('/login')">Masuk</button>
      </div>
    </div>
    <div class="features">
      <div class="feature-card"><div class="feature-icon">✏️</div><h3>Spelling Test</h3><p>Dengarkan kata dari AI dan ketik jawabanmu secepat mungkin. Solo atau multiplayer!</p></div>
      <div class="feature-card"><div class="feature-icon">🎙️</div><h3>Speaking Test</h3><p>Baca teks yang diberikan AI, rekam suaramu, dan Whisper AI menilai akurasimu.</p></div>
      <div class="feature-card"><div class="feature-icon">🌐</div><h3>Translator</h3><p>Terjemahkan teks antar bahasa menggunakan AI dengan streaming realtime.</p></div>
      <div class="feature-card"><div class="feature-icon">🏆</div><h3>Leaderboard</h3><p>Bersaing di leaderboard global dan buktikan kemampuan bahasamu!</p></div>
    </div>
  </div>`;
};

// ── Login ─────────────────────────────────────────────────────
routes['/login'] = () => {
  $('navbar').classList.add('hidden');
  view().innerHTML = `
  <div class="auth-container">
    <div class="auth-logo">⚡ <span class="gradient-text">LangComp</span></div>
    <div class="card">
      <h2>Masuk</h2>
      <div id="login-alert"></div>
      <div class="form-group"><label>Email</label><input id="l-email" type="email" placeholder="email@contoh.com" autofocus></div>
      <div class="form-group"><label>Password</label><input id="l-pass" type="password" placeholder="••••••••"></div>
      <button class="btn btn-primary btn-block" onclick="doLogin()">Masuk</button>
    </div>
    <div class="auth-footer">Belum punya akun? <a onclick="navigate('/register')">Daftar sekarang</a></div>
  </div>`;
  document.addEventListener('keydown', function h(e) { if(e.key==='Enter'){ doLogin(); document.removeEventListener('keydown',h); } });
};

async function doLogin() {
  const email = $('l-email')?.value;
  const pass = $('l-pass')?.value;
  if (!email || !pass) return;
  const btn = document.querySelector('.btn-primary');
  btn.disabled = true; btn.textContent = 'Memproses...';
  try {
    const res = await fetch('/api/auth/login', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ email, password: pass }) });
    const data = await res.json();
    if (!res.ok) { $('login-alert').innerHTML = `<div class="alert alert-error">${html(data.error)}</div>`; btn.disabled=false; btn.textContent='Masuk'; return; }
    App.token = data.token; App.user = data.user;
    localStorage.setItem('token', data.token);
    localStorage.setItem('user', JSON.stringify(data.user));
    initSocket();
    navigate('/dashboard');
  } catch { $('login-alert').innerHTML = `<div class="alert alert-error">Gagal terhubung ke server</div>`; btn.disabled=false; btn.textContent='Masuk'; }
}

// ── Register ──────────────────────────────────────────────────
routes['/register'] = () => {
  $('navbar').classList.add('hidden');
  view().innerHTML = `
  <div class="auth-container">
    <div class="auth-logo">⚡ <span class="gradient-text">LangComp</span></div>
    <div class="card">
      <h2>Daftar</h2>
      <div id="reg-alert"></div>
      <div class="form-group"><label>Username</label><input id="r-user" type="text" placeholder="username123" autofocus></div>
      <div class="form-group"><label>Email</label><input id="r-email" type="email" placeholder="email@contoh.com"></div>
      <div class="form-group"><label>Password</label><input id="r-pass" type="password" placeholder="Min. 8 karakter"></div>
      <button class="btn btn-primary btn-block" onclick="doRegister()">Daftar</button>
    </div>
    <div class="auth-footer">Sudah punya akun? <a onclick="navigate('/login')">Masuk</a></div>
  </div>`;
};

async function doRegister() {
  const username = $('r-user')?.value;
  const email = $('r-email')?.value;
  const password = $('r-pass')?.value;
  if (!username||!email||!password) return;
  const btn = document.querySelector('.btn-primary');
  btn.disabled=true; btn.textContent='Mendaftar...';
  try {
    const res = await fetch('/api/auth/register', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({username,email,password}) });
    const data = await res.json();
    if (!res.ok) { $('reg-alert').innerHTML=`<div class="alert alert-error">${html(data.error)}</div>`; btn.disabled=false; btn.textContent='Daftar'; return; }
    toast('Registrasi berhasil! Silakan masuk.','success');
    navigate('/login');
  } catch { $('reg-alert').innerHTML=`<div class="alert alert-error">Gagal terhubung</div>`; btn.disabled=false; btn.textContent='Daftar'; }
}

// ── Dashboard ─────────────────────────────────────────────────
routes['/dashboard'] = requireAuth(async () => {
  $('navbar').classList.remove('hidden');
  $('nav-username').textContent = App.user?.username || '';
  initSocket();
  view().innerHTML = `
  <div class="container">
    <h1>Selamat datang, <span class="gradient-text">${html(App.user.username)}</span> 👋</h1>
    <p style="margin-bottom:32px">Pilih mode permainan atau buat room baru</p>
    <div class="grid-3">
      <div class="card" style="cursor:pointer;text-align:center" onclick="navigate('/spelling-solo')">
        <div style="font-size:48px;margin-bottom:12px">✏️</div>
        <h3>Spelling Solo</h3>
        <p>Latih spelling-mu sendirian</p>
      </div>
      <div class="card" style="cursor:pointer;text-align:center" onclick="navigate('/speaking-solo')">
        <div style="font-size:48px;margin-bottom:12px">🎙️</div>
        <h3>Speaking Solo</h3>
        <p>Latih pelafalan dengan AI</p>
      </div>
      <div class="card" style="cursor:pointer;text-align:center" onclick="navigate('/translate')">
        <div style="font-size:48px;margin-bottom:12px">🌐</div>
        <h3>Translator</h3>
        <p>Terjemahkan teks dengan AI</p>
      </div>
    </div>
    <div class="grid-2" style="margin-top:20px">
      <button class="btn btn-primary" onclick="navigate('/lobby')" style="width:100%;padding:20px;font-size:1.1rem">🏟️ Lihat Lobby Multiplayer</button>
      <button class="btn btn-outline" onclick="navigate('/create-room')" style="width:100%;padding:20px;font-size:1.1rem">➕ Buat Room Baru</button>
    </div>
    <div class="card" style="margin-top:20px">
      <h3>🏆 Leaderboard Kilat</h3>
      <div id="dash-lb">Memuat...</div>
    </div>
  </div>`;
  try {
    const res = await api('GET', '/leaderboard/spelling?limit=5');
    const data = await res.json();
    const lb = data.leaderboard || [];
    $('dash-lb').innerHTML = lb.length ? `<table class="lb-table"><thead><tr><th>#</th><th>Player</th><th>Score</th></tr></thead><tbody>${lb.map(r=>`<tr><td class="rank-${r.rank}">#${r.rank}</td><td>${html(r.username)}</td><td>${r.total_score}</td></tr>`).join('')}</tbody></table>` : '<p>Belum ada data</p>';
  } catch {}
});

// ── Lobby ─────────────────────────────────────────────────────
routes['/lobby'] = requireAuth(async () => {
  $('navbar').classList.remove('hidden');
  view().innerHTML = `
  <div class="container">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:24px">
      <h2>🏟️ Public Lobby</h2>
      <div style="display:flex;gap:12px">
        <button class="btn btn-ghost" onclick="showJoinModal()">🔑 Join dengan Kode</button>
        <button class="btn btn-primary" onclick="navigate('/create-room')">➕ Buat Room</button>
      </div>
    </div>
    <div id="rooms-grid" class="rooms-grid"><div style="text-align:center;padding:40px;color:var(--text2)">⏳ Memuat rooms...</div></div>
  </div>
  <div id="join-modal" class="modal-overlay hidden">
    <div class="modal">
      <h2>🔑 Join Room</h2>
      <div class="form-group"><label>Kode Room</label><input id="join-code" placeholder="Contoh: A1B2C3D4" style="text-transform:uppercase;letter-spacing:4px"></div>
      <div class="modal-btns">
        <button class="btn btn-ghost" onclick="$('join-modal').classList.add('hidden')">Batal</button>
        <button class="btn btn-primary" onclick="doJoinCode()">Join</button>
      </div>
    </div>
  </div>`;
  loadRooms();
  setInterval(loadRooms, 5000);
});

async function loadRooms() {
  try {
    const res = await api('GET', '/rooms');
    const data = await res.json();
    const grid = $('rooms-grid');
    if (!grid) return;
    if (!data.rooms?.length) { grid.innerHTML = '<div style="text-align:center;padding:40px;color:var(--text2)">Belum ada room aktif. Buat room baru!</div>'; return; }
    grid.innerHTML = data.rooms.map(r => `
      <div class="room-card" onclick="joinRoomById('${r.id}','${r.code}')">
        <h3>${html(r.name)}</h3>
        <div class="room-meta">
          <span class="badge badge-blue">${r.mode}</span>
          <span class="badge badge-${r.level==='easy'?'green':r.level==='medium'?'yellow':'red'}">${r.level}</span>
          ${r.is_public?'<span class="badge badge-green">Publik</span>':'<span class="badge badge-red">Private</span>'}
        </div>
        <div class="room-players">👥 ${r.player_count}/${r.max_players} pemain • Host: ${html(r.host_name)}</div>
        <div style="margin-top:8px;font-size:.8rem;color:var(--text2)">Kode: <code>${r.code}</code></div>
      </div>`).join('');
  } catch {}
}

function showJoinModal() { $('join-modal').classList.remove('hidden'); $('join-code').focus(); }

async function doJoinCode() {
  const code = $('join-code')?.value?.trim().toUpperCase();
  if (!code) return;
  try {
    const res = await api('GET', `/rooms/join/${code}`);
    const data = await res.json();
    if (!res.ok) { toast(data.error, 'error'); return; }
    App.currentRoom = data.room;
    navigate('/room', { room: data.room });
  } catch { toast('Gagal join room', 'error'); }
}

async function joinRoomById(id, code) {
  try {
    const res = await api('GET', `/rooms/join/${code}`);
    const data = await res.json();
    if (!res.ok) { toast(data.error, 'error'); return; }
    App.currentRoom = data.room;
    navigate('/room', { room: data.room });
  } catch { toast('Gagal join room', 'error'); }
}

// ── Create Room ───────────────────────────────────────────────
routes['/create-room'] = requireAuth(() => {
  $('navbar').classList.remove('hidden');
  view().innerHTML = `
  <div class="container" style="max-width:560px">
    <h2>➕ Buat Room Baru</h2>
    <div class="card">
      <div class="form-group"><label>Nama Room</label><input id="cr-name" placeholder="Room seru saya"></div>
      <div class="form-row">
        <div class="form-group"><label>Mode</label><select id="cr-mode"><option value="spelling">Spelling Test</option><option value="speaking">Speaking Test</option></select></div>
        <div class="form-group"><label>Level</label><select id="cr-level"><option value="easy">Easy</option><option value="medium" selected>Medium</option><option value="hard">Hard</option></select></div>
      </div>
      <div class="form-row">
        <div class="form-group"><label>Maks. Pemain</label><input id="cr-max" type="number" value="4" min="2" max="10"></div>
        <div class="form-group"><label>Durasi (detik)</label><input id="cr-dur" type="number" value="300" min="60" max="3600"></div>
      </div>
      <div class="form-row">
        <div class="form-group"><label>Waktu Jawab (detik)</label><input id="cr-ans" type="number" value="30" min="10" max="120"></div>
        <div class="form-group"><label>Maks. Kata</label><input id="cr-words" type="number" value="10" min="1" max="50"></div>
      </div>
      <div class="form-group">
        <label><input id="cr-public" type="checkbox" checked> Room Publik</label>
      </div>
      <div style="display:flex;gap:12px;margin-top:8px">
        <button class="btn btn-ghost" onclick="navigate('/lobby')">Batal</button>
        <button class="btn btn-primary" onclick="doCreateRoom()">Buat Room</button>
      </div>
    </div>
  </div>`;
});

async function doCreateRoom() {
  const body = {
    name: $('cr-name').value, mode: $('cr-mode').value, level: $('cr-level').value,
    is_public: $('cr-public').checked, max_players: parseInt($('cr-max').value),
    match_duration: parseInt($('cr-dur').value), answer_time: parseInt($('cr-ans').value),
    max_words: parseInt($('cr-words').value)
  };
  if (!body.name) { toast('Masukkan nama room', 'error'); return; }
  try {
    const res = await api('POST', '/rooms', body);
    const data = await res.json();
    if (!res.ok) { toast(data.error, 'error'); return; }
    App.currentRoom = data.room;
    navigate('/room', { room: data.room });
  } catch { toast('Gagal membuat room', 'error'); }
}

// ── Room Lobby ────────────────────────────────────────────────
routes['/room'] = requireAuth(async (data) => {
  const room = data.room || App.currentRoom;
  if (!room) { navigate('/lobby'); return; }
  $('navbar').classList.remove('hidden');
  const isHost = room.host_id === App.user.id;

  view().innerHTML = `
  <div class="container" style="max-width:700px">
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:start">
        <div>
          <h2>${html(room.name)}</h2>
          <div class="room-meta">
            <span class="badge badge-blue">${room.mode}</span>
            <span class="badge badge-yellow">${room.level}</span>
            <span class="badge badge-green">${room.is_public?'Publik':'Private'}</span>
          </div>
        </div>
        <div style="text-align:right">
          <div style="font-size:.85rem;color:var(--text2)">Kode Room:</div>
          <div style="font-size:1.8rem;font-weight:800;letter-spacing:6px;font-family:'JetBrains Mono',monospace">${room.code}</div>
        </div>
      </div>
      <div style="margin-top:20px">
        <h3>👥 Pemain</h3>
        <div id="players-list" style="margin-top:12px"></div>
      </div>
      <div class="chat-panel" id="chat-msgs"></div>
      <div class="chat-input-row">
        <input id="chat-in" placeholder="Ketik pesan..." onkeydown="if(event.key==='Enter')sendChat()">
        <button class="btn btn-ghost" onclick="sendChat()">Kirim</button>
      </div>
      <div style="margin-top:20px;display:flex;gap:12px">
        <button class="btn btn-ghost" onclick="navigate('/lobby')">← Keluar</button>
        ${isHost ? `<button class="btn btn-success" id="ready-btn" onclick="markReady()" style="flex:1">✅ Ready</button><button class="btn btn-primary" id="start-btn" onclick="startGame()" style="flex:1">🚀 Mulai Game</button>` : `<button class="btn btn-success btn-block" id="ready-btn" onclick="markReady()">✅ Saya Siap</button>`}
      </div>
    </div>
  </div>`;

  initSocket();
  App.socket.emit('room:join', { roomId: room.id });

  App.socket.on('room:players', ({ players }) => {
    const list = $('players-list');
    if (!list) return;
    list.innerHTML = Object.entries(players).map(([id, p]) => `
      <div class="score-item">
        <span>${html(p.username)} ${id===App.user.id?'(Kamu)':''}</span>
        <span class="badge ${p.ready?'badge-green':'badge-blue'}">${p.ready?'✅ Siap':'⏳ Menunggu'}</span>
      </div>`).join('');
  });

  App.socket.on('game:start', ({ roomId }) => {
    App.currentRoom = room;
    if (room.mode === 'spelling') navigate('/spelling', { room, matchId: null });
    else navigate('/speaking', { room, matchId: null });
  });

  App.socket.on('chat:message', ({ username, message }) => {
    const msgs = $('chat-msgs');
    if (!msgs) return;
    msgs.innerHTML += `<div class="chat-msg"><strong>${html(username)}:</strong> ${html(message)}</div>`;
    msgs.scrollTop = msgs.scrollHeight;
  });
}); // end room route

function markReady() {
  const room = App.currentRoom;
  if (!room) return;
  App.socket.emit('room:ready', { roomId: room.id });
  const btn = $('ready-btn');
  if (btn) { btn.textContent = '✅ Siap!'; btn.disabled = true; }
}

function sendChat() {
  const inp = $('chat-in');
  if (!inp || !inp.value.trim() || !App.currentRoom) return;
  App.socket.emit('chat:message', { roomId: App.currentRoom.id, message: inp.value });
  inp.value = '';
}

async function startGame() {
  const room = App.currentRoom;
  if (!room) return;
  try {
    const res = await api('POST', `/rooms/${room.id}/start`);
    const data = await res.json();
    App.currentMatch = data.matchId;
    App.socket.emit('room:start', { roomId: room.id });
  } catch { toast('Gagal memulai game', 'error'); }
}

// ── Spelling Test ─────────────────────────────────────────────
routes['/spelling-solo'] = requireAuth(async () => {
  $('navbar').classList.remove('hidden');
  await startSpelling(null, true);
});
routes['/spelling'] = requireAuth(async (data) => {
  $('navbar').classList.remove('hidden');
  await startSpelling(data.room, false);
});

async function startSpelling(room, isSolo) {
  const level = room?.level || 'medium';
  const answerTime = room?.answer_time || 30;
  let score = 0, qNum = 0, totalQ = room?.max_words || 10;
  let currentWord = '', timer, startTime;

  // Create match record
  let matchId;
  try {
    const mRes = await api('POST', '/rooms/' + (room?.id || 'solo') + '/start').catch(() => null);
    // Use a temp match ID for solo
    matchId = 'solo-' + Date.now();
  } catch {}

  setupVisibilityAPI(room?.id);

  function renderGame() {
    view().innerHTML = `
    <div class="game-layout container">
      <div class="game-main">
        <div class="game-header">
          <div>
            <div style="color:var(--text2);font-size:.85rem">Pertanyaan ${qNum}/${totalQ}</div>
            <div class="progress-bar" style="width:200px;margin-top:6px"><div class="progress-fill" style="width:${(qNum/totalQ)*100}%"></div></div>
          </div>
          <div class="score-display"><span class="gradient-text">${score}</span> pts</div>
          <div class="timer-ring" id="timer-ring">
            <svg width="80" height="80" viewBox="0 0 80 80">
              <circle cx="40" cy="40" r="34" stroke="var(--bg3)" stroke-width="6" fill="none"/>
              <circle id="ring-circle" class="ring-progress" cx="40" cy="40" r="34" stroke="var(--accent)" stroke-width="6" fill="none" stroke-dasharray="${2*Math.PI*34}" stroke-dashoffset="0"/>
            </svg>
            <div class="timer-text" id="timer-txt">${answerTime}</div>
          </div>
        </div>
        <div id="word-box" class="word-display" style="color:var(--text2);font-size:1.2rem">Memuat kata...</div>
        <div class="form-group">
          <input id="ans-in" class="answer-input" placeholder="Ketik kata yang didengar..." autocomplete="off" autocorrect="off">
        </div>
        <div id="fb" class="result-feedback" style="display:none"></div>
        <div style="display:flex;gap:12px">
          <button class="btn btn-ghost" onclick="endGame()">🚪 Keluar</button>
          <button class="btn btn-primary" id="submit-btn" onclick="submitAnswer()">✅ Submit</button>
          <button class="btn btn-outline" id="tts-btn" onclick="playWordTTS()">🔊 Dengarkan Lagi</button>
        </div>
      </div>
      ${!isSolo ? `<div class="scores-panel"><h3>👥 Skor</h3><div id="scores-live">Menunggu...</div></div>` : ''}
    </div>`;
    $('ans-in').addEventListener('keydown', e => { if(e.key==='Enter') submitAnswer(); });
    if (room && App.socket) {
      App.socket.on('game:scores', ({ players }) => {
        const el = $('scores-live');
        if (!el) return;
        const sorted = Object.values(players).sort((a,b) => b.score-a.score);
        el.innerHTML = sorted.map(p => `<div class="score-item"><span>${html(p.username)}</span><span class="score-value">${p.score}</span></div>`).join('');
      });
    }
    nextQuestion();
  }

  async function nextQuestion() {
    qNum++;
    if (qNum > totalQ) { endGame(); return; }
    clearInterval(timer);
    const el = $('word-box');
    const inp = $('ans-in');
    const fb = $('fb');
    if (!el || !inp) return;
    el.textContent = '⏳ Memuat...';
    inp.value = '';
    inp.className = 'answer-input';
    fb.style.display = 'none';
    inp.disabled = true;
    try {
      const res = await api('GET', `/game/word?level=${level}&count=1`);
      const data = await res.json();
      currentWord = data.words?.[0] || 'language';
    } catch { currentWord = ['language','challenge','practice','knowledge','competition'][Math.floor(Math.random()*5)]; }
    el.textContent = '🔊 Mendengarkan...';
    await playWordTTS();
    el.innerHTML = `<span style="color:var(--text2);font-size:1rem">⬆ Dengarkan dan ketik kata di atas</span><br><span style="font-size:.85rem;opacity:.5">Kata ${qNum} dari ${totalQ}</span>`;
    inp.disabled = false;
    inp.focus();
    startTime = Date.now();
    startTimer(answerTime);
  }

  function startTimer(secs) {
    let rem = secs;
    const circle = $('ring-circle');
    const txt = $('timer-txt');
    const circumf = 2 * Math.PI * 34;
    timer = setInterval(() => {
      rem--;
      if (txt) txt.textContent = rem;
      const pct = rem / secs;
      if (circle) { circle.style.strokeDashoffset = circumf * (1 - pct); circle.style.stroke = rem <= 5 ? 'var(--red)' : rem <= 10 ? 'var(--yellow)' : 'var(--accent)'; }
      if (txt && rem <= 5) txt.style.color = 'var(--red)';
      if (rem <= 0) { clearInterval(timer); submitAnswer(true); }
    }, 1000);
  }

  async function playWordTTS() {
    const btn = $('tts-btn');
    if (btn) { btn.disabled = true; btn.textContent = '⏳'; }
    try {
      const audio = new Audio(`/api/tts/speak?text=${encodeURIComponent(currentWord)}&voice=en-US-GuyNeural`);
      audio.play();
      await new Promise(r => audio.addEventListener('ended', r));
    } catch {}
    if (btn) { btn.disabled = false; btn.textContent = '🔊 Dengarkan Lagi'; }
  }

  function submitAnswer(timeout=false) {
    clearInterval(timer);
    const inp = $('ans-in');
    const fb = $('fb');
    if (!inp || !fb) return;
    const ans = inp.value.trim();
    const rt = (Date.now() - startTime) / 1000;
    let result, points;
    const dist = levenshtein(ans.toLowerCase(), currentWord.toLowerCase());
    if (dist === 0) { result='correct'; points=10+(rt<3?3:0); }
    else if (dist<=2) { result='almost'; points=5; }
    else { result='wrong'; points=0; }
    if (timeout && !ans) { result='wrong'; points=0; }
    score += points;
    inp.className = `answer-input ${result}`;
    fb.className = `result-feedback ${result}`;
    fb.textContent = result==='correct' ? `✅ Benar! +${points} pts` : result==='almost' ? `🟡 Hampir! Kata: "${currentWord}" +${points} pts` : `❌ Salah! Kata: "${currentWord}"`;
    fb.style.display = 'block';
    document.querySelector('.score-display').innerHTML = `<span class="gradient-text">${score}</span> pts`;
    if (room && App.socket) App.socket.emit('spelling:answer', { roomId: room.id, answer: ans, word: currentWord, responseTime: rt });
    setTimeout(nextQuestion, 1800);
  }

  function endGame() {
    clearInterval(timer);
    if (room && App.socket) App.socket.emit('game:end', { roomId: room.id });
    api('POST', '/game/result/spelling', { matchId, score, correctCount: 0, almostCount: 0, wrongCount: 0, avgResponseTime: 0 }).catch(() => {});
    navigate('/result', { score, mode: 'spelling', matchId });
  }

  renderGame();
}

function levenshtein(a, b) {
  const m = a.length, n = b.length;
  const dp = Array.from({length:m+1}, (_,i) => Array.from({length:n+1}, (_,j) => i===0?j:j===0?i:0));
  for(let i=1;i<=m;i++) for(let j=1;j<=n;j++) dp[i][j]=a[i-1]===b[j-1]?dp[i-1][j-1]:1+Math.min(dp[i-1][j],dp[i][j-1],dp[i-1][j-1]);
  return dp[m][n];
}

// ── Speaking Test ─────────────────────────────────────────────
routes['/speaking-solo'] = requireAuth(async () => {
  $('navbar').classList.remove('hidden');
  await startSpeaking(null, true);
});
routes['/speaking'] = requireAuth(async (data) => {
  $('navbar').classList.remove('hidden');
  await startSpeaking(data.room, false);
});

async function startSpeaking(room, isSolo) {
  const level = room?.level || 'medium';
  const levelMap = { easy:'word', medium:'sentence', hard:'paragraph' };
  const textLevel = levelMap[level];
  const maxWords = room?.max_words || 20;
  let qNum = 0, totalQ = isSolo ? 5 : (room?.max_words || 5);
  let currentText = '', mediaRecorder, chunks=[], recording=false, overallScore=0;

  setupVisibilityAPI(room?.id);

  async function renderQuestion() {
    qNum++;
    if (qNum > totalQ) { endSpeaking(); return; }
    view().innerHTML = `
    <div class="game-area container">
      <div class="game-header">
        <div>Pertanyaan ${qNum}/${totalQ}</div>
        <div class="score-display"><span class="gradient-text">${overallScore}</span> pts</div>
        <button class="btn btn-ghost" onclick="endSpeaking()">Keluar</button>
      </div>
      <div class="card">
        <p style="color:var(--text2);margin-bottom:12px">Baca dan lafalkan teks berikut:</p>
        <div id="speak-text" class="word-display" style="font-size:1.3rem;letter-spacing:1px;text-align:left">⏳ Memuat...</div>
        <div class="waveform inactive" id="waveform">${Array(8).fill('<div class="wave-bar"></div>').join('')}</div>
        <div style="text-align:center;margin:12px 0">
          <button class="record-btn" id="rec-btn" onclick="toggleRecord()">🎙️</button>
          <div id="rec-status" style="margin-top:8px;color:var(--text2);font-size:.875rem">Klik untuk merekam</div>
        </div>
        <div id="transcript-area" style="display:none">
          <h3>Transkripsi Kamu:</h3>
          <div class="transcript-display" id="transcript"></div>
          <div id="score-display" style="text-align:center;margin-top:16px"></div>
        </div>
        <div id="fb-speak" style="display:none"></div>
      </div>
    </div>`;
    try {
      const res = await api('GET', `/game/text?level=${textLevel}&maxWords=${maxWords}`);
      const data = await res.json();
      currentText = data.text || 'The quick brown fox jumps over the lazy dog.';
    } catch { currentText = 'The quick brown fox jumps over the lazy dog.'; }
    $('speak-text').textContent = currentText;
  }

  function toggleRecord() {
    recording ? stopRecord() : startRecord();
  }

  async function startRecord() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      chunks = [];
      mediaRecorder = new MediaRecorder(stream);
      mediaRecorder.ondataavailable = e => chunks.push(e.data);
      mediaRecorder.onstop = async () => {
        stream.getTracks().forEach(t => t.stop());
        await processAudio();
      };
      mediaRecorder.start();
      recording = true;
      const btn = $('rec-btn');
      const wf = $('waveform');
      const st = $('rec-status');
      if (btn) { btn.classList.add('recording'); btn.textContent = '⏹️'; }
      if (wf) wf.classList.remove('inactive');
      if (st) st.textContent = 'Merekam... Klik untuk berhenti';
    } catch { toast('Tidak dapat mengakses mikrofon', 'error'); }
  }

  function stopRecord() {
    if (mediaRecorder && recording) { mediaRecorder.stop(); recording = false; }
    const btn = $('rec-btn');
    const wf = $('waveform');
    const st = $('rec-status');
    if (btn) { btn.classList.remove('recording'); btn.textContent = '⏳'; btn.disabled = true; }
    if (wf) wf.classList.add('inactive');
    if (st) st.textContent = 'Memproses...';
  }

  async function processAudio() {
    const blob = new Blob(chunks, { type: 'audio/webm' });
    const form = new FormData();
    form.append('audio', blob, 'recording.webm');
    const startT = Date.now();
    try {
      const res = await api('POST', '/game/transcribe', form, true);
      const data = await res.json();
      const transcription = data.transcription || '';
      const rt = (Date.now() - startT) / 1000;

      const scoreRes = await api('POST', '/game/score/speaking', { original: currentText, transcription });
      const scoreData = await scoreRes.json();
      const { accuracy, grade, score } = scoreData;
      overallScore += score;

      // Show result
      const ta = $('transcript-area');
      const tr = $('transcript');
      const sd = $('score-display');
      const fb = $('fb-speak');
      if (ta) ta.style.display = 'block';
      if (tr) tr.innerHTML = highlightWords(currentText, transcription);
      if (sd) sd.innerHTML = `<div style="font-size:2rem;font-weight:800;color:${grade==='correct'?'var(--green)':grade==='almost'?'var(--yellow)':'var(--red)'}">${accuracy}%</div><div style="color:var(--text2)">Akurasi • ${rt.toFixed(1)}s</div>`;
      if (fb) { fb.className = `result-feedback ${grade}`; fb.textContent = grade==='correct'?'✅ Sangat Bagus!':grade==='almost'?'🟡 Hampir Sempurna!':'❌ Perlu Latihan Lagi'; fb.style.display='block'; }

      await api('POST', '/game/result/speaking', { matchId:'solo-'+Date.now(), originalText:currentText, transcription, accuracy, wordAccuracy:accuracy, responseTime:rt, score });
      setTimeout(renderQuestion, 3000);
    } catch {
      toast('Transkripsi gagal', 'error');
      const btn = $('rec-btn');
      if (btn) { btn.disabled=false; btn.textContent='🎙️'; }
    }
  }

  function highlightWords(original, transcription) {
    const orig = original.toLowerCase().split(/\s+/);
    const trans = transcription.toLowerCase().split(/\s+/);
    return orig.map((w, i) => {
      const cls = trans[i]===w ? 'word-correct' : trans[i] && levenshtein(trans[i],w)<=2 ? 'word-almost' : 'word-wrong';
      return `<span class="${cls}">${html(w)} </span>`;
    }).join('');
  }

  function endSpeaking() {
    navigate('/result', { score: overallScore, mode: 'speaking' });
  }

  await renderQuestion();
}

// ── Translator ─────────────────────────────────────────────────
routes['/translate'] = requireAuth(() => {
  $('navbar').classList.remove('hidden');
  const langs = [['id','Indonesia'],['en','English'],['es','Spanish'],['fr','French'],['de','German'],['ja','Japanese'],['zh','Chinese'],['ar','Arabic'],['ko','Korean'],['pt','Portuguese']];
  const langOpts = langs.map(([v,l]) => `<option value="${v}">${l}</option>`).join('');

  view().innerHTML = `
  <div class="container">
    <h2>🌐 AI Translator</h2>
    <div class="card">
      <div class="form-row" style="margin-bottom:16px">
        <div class="form-group"><label>Bahasa Sumber</label><select id="src-lang">${langOpts}</select></div>
        <div class="form-group"><label>Bahasa Target</label><select id="tgt-lang">${langs.map(([v,l])=>`<option value="${v}" ${v==='en'?'selected':''}>${l}</option>`).join('')}</select></div>
        <div class="form-group"><label>Maks. Kata Output</label><input id="max-w" type="number" value="100" min="10" max="500"></div>
      </div>
      <div class="translate-area">
        <div>
          <label>Teks Sumber</label>
          <textarea id="src-text" class="translate-box" placeholder="Masukkan teks untuk diterjemahkan..." oninput="updateWordCount()"></textarea>
          <div class="translate-meta"><span class="word-counter" id="wc-src">0 kata</span></div>
        </div>
        <div class="translate-swap" onclick="swapLangs()" data-tooltip="Tukar bahasa">⇄</div>
        <div>
          <label>Hasil Terjemahan</label>
          <div id="tgt-text" class="translate-box" style="min-height:200px;white-space:pre-wrap"></div>
          <div class="translate-meta">
            <span class="word-counter" id="wc-tgt">0 kata</span>
            <div style="display:flex;gap:8px">
              <button class="btn btn-sm" onclick="copyResult()">📋 Copy</button>
              <button class="btn btn-sm" onclick="speakResult()">🔊 Dengar</button>
            </div>
          </div>
        </div>
      </div>
      <div style="margin-top:16px">
        <button class="btn btn-primary" id="trans-btn" onclick="doTranslate()">🌐 Terjemahkan</button>
        <button class="btn btn-ghost" id="stop-btn" onclick="stopTranslate()" style="display:none">⏹ Stop</button>
      </div>
    </div>
  </div>`;
});

let translateController = null;

function updateWordCount() {
  const t = $('src-text')?.value || '';
  const wc = t.trim() ? t.trim().split(/\s+/).length : 0;
  if($('wc-src')) $('wc-src').textContent = `${wc} kata`;
}

function swapLangs() {
  const s = $('src-lang'), t = $('tgt-lang'), st = $('src-text'), tt = $('tgt-text');
  [s.value, t.value] = [t.value, s.value];
  if(tt) { st.value = tt.textContent; tt.textContent = ''; }
  updateWordCount();
}

async function doTranslate() {
  const text = $('src-text')?.value?.trim();
  if (!text) return toast('Masukkan teks', 'error');
  const srcLang = $('src-lang').value;
  const tgtLang = $('tgt-lang').value;
  const maxWords = parseInt($('max-w').value) || 100;
  const btn = $('trans-btn');
  const stop = $('stop-btn');
  const out = $('tgt-text');
  btn.style.display='none'; stop.style.display='inline-flex';
  out.textContent = '';
  translateController = new AbortController();
  try {
    const res = await fetch('/api/translate', {
      method: 'POST', headers: {'Content-Type':'application/json','Authorization':`Bearer ${App.token}`},
      body: JSON.stringify({ text, sourceLang: srcLang, targetLang: tgtLang, maxWords }),
      signal: translateController.signal
    });
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let result = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const lines = decoder.decode(value).split('\n').filter(l => l.startsWith('data:'));
      for (const line of lines) {
        try {
          const d = JSON.parse(line.slice(5));
          if (d.token) { result += d.token; out.textContent = result; if($('wc-tgt')) $('wc-tgt').textContent = result.trim().split(/\s+/).length + ' kata'; }
          if (d.done || d.error) break;
        } catch {}
      }
    }
  } catch (e) { if (e.name !== 'AbortError') toast('Terjemahan gagal','error'); }
  finally { btn.style.display='inline-flex'; stop.style.display='none'; }
}

function stopTranslate() { if(translateController) { translateController.abort(); translateController=null; } }

function copyResult() {
  const t = $('tgt-text')?.textContent;
  if (t) { navigator.clipboard.writeText(t).then(() => toast('Disalin!','success')); }
}

function speakResult() {
  const t = $('tgt-text')?.textContent;
  const lang = $('tgt-lang')?.value || 'en';
  const voices = {en:'en-US-GuyNeural',id:'id-ID-ArdiNeural',es:'es-ES-AlvaroNeural',fr:'fr-FR-HenriNeural',de:'de-DE-ConradNeural',ja:'ja-JP-KeitaNeural',zh:'zh-CN-YunxiNeural',ko:'ko-KR-InJoonNeural'};
  if (t) new Audio(`/api/tts/speak?text=${encodeURIComponent(t.slice(0,300))}&voice=${voices[lang]||'en-US-GuyNeural'}`).play().catch(()=>{});
}

// ── Result ────────────────────────────────────────────────────
routes['/result'] = requireAuth(async (data) => {
  $('navbar').classList.remove('hidden');
  const { score=0, mode='spelling', matchId } = data;
  let lbData = [];
  if (matchId && !matchId.startsWith('solo')) {
    try {
      const res = await api('GET', `/leaderboard/match/${matchId}`);
      const d = await res.json();
      lbData = d.results || [];
    } catch {}
  }
  view().innerHTML = `
  <div class="container" style="max-width:600px;text-align:center">
    <div class="card">
      <div style="font-size:64px;margin-bottom:16px">${score>=50?'🏆':score>=20?'🎯':'💪'}</div>
      <h1>Game Selesai!</h1>
      <div class="stat-box" style="margin:24px 0">
        <div class="stat-value gradient-text">${score}</div>
        <div class="stat-label">Poin Total — ${mode}</div>
      </div>
      ${lbData.length ? `<h3 style="margin-bottom:12px">🏅 Hasil Match</h3>
      <table class="lb-table" style="margin-bottom:20px">
        <thead><tr><th>#</th><th>Player</th><th>Score</th></tr></thead>
        <tbody>${lbData.map(r=>`<tr class="${r.user_id===App.user.id?'me':''}"><td class="rank-${r.rank}">#${r.rank}</td><td>${html(r.username)}</td><td>${r.score}</td></tr>`).join('')}</tbody>
      </table>` : ''}
      <div style="display:flex;gap:12px;justify-content:center">
        <button class="btn btn-primary" onclick="navigate('/dashboard')">🏠 Dashboard</button>
        <button class="btn btn-outline" onclick="navigate('/leaderboard')">🏆 Leaderboard</button>
        <button class="btn btn-ghost" onclick="navigate('/${mode}-solo')">🔄 Main Lagi</button>
      </div>
    </div>
  </div>`;
});

// ── Leaderboard ───────────────────────────────────────────────
routes['/leaderboard'] = requireAuth(async () => {
  $('navbar').classList.remove('hidden');
  let period = 'alltime', lbMode = 'spelling';
  async function loadLB() {
    const endpoint = lbMode === 'spelling' ? '/leaderboard/spelling' : '/leaderboard/speaking';
    try {
      const res = await api('GET', `${endpoint}?period=${period}`);
      const data = await res.json();
      const lb = data.leaderboard || [];
      $('lb-body').innerHTML = lb.length ? lb.map(r => `
        <tr class="${r.user_id===App.user.id?'me lb-row-enter':''}">
          <td><span class="rank-${r.rank}">${r.rank<=3?['🥇','🥈','🥉'][r.rank-1]:'#'+r.rank}</span></td>
          <td>${html(r.username)}</td>
          <td><span class="score-value">${r.total_score||r.total_score}</span></td>
          ${lbMode==='spelling'?`<td>${r.total_correct||0}</td><td>${r.total_matches||0}</td><td>${r.total_wins||0}</td>`:
          `<td>${(r.avg_accuracy||0).toFixed(1)}%</td><td>${r.total_tests||0}</td><td>${r.highest_score||0}</td>`}
        </tr>`).join('') : '<tr><td colspan="6" style="text-align:center;padding:40px;color:var(--text2)">Belum ada data</td></tr>';
    } catch { $('lb-body').innerHTML = '<tr><td colspan="6" style="text-align:center;color:var(--red)">Gagal memuat</td></tr>'; }
  }

  view().innerHTML = `
  <div class="container">
    <h2>🏆 Global Leaderboard</h2>
    <div style="display:flex;gap:12px;margin-bottom:16px">
      <div class="filter-tabs" style="flex:1">
        ${['spelling','speaking'].map(m=>`<div class="filter-tab ${m===lbMode?'active':''}" onclick="changeLBMode('${m}',this)">${m==='spelling'?'✏️ Spelling':'🎙️ Speaking'}</div>`).join('')}
      </div>
    </div>
    <div class="filter-tabs">
      ${[['alltime','Semua'],['monthly','Bulanan'],['weekly','Mingguan'],['daily','Harian']].map(([v,l])=>`<div class="filter-tab ${v===period?'active':''}" onclick="changeLBPeriod('${v}',this)">${l}</div>`).join('')}
    </div>
    <div class="card" style="padding:0;overflow:hidden">
      <table class="lb-table">
        <thead><tr><th>#</th><th>Player</th><th>Score</th>${lbMode==='spelling'?'<th>Benar</th><th>Match</th><th>Menang</th>':'<th>Akurasi</th><th>Test</th><th>Tertinggi</th>'}</tr></thead>
        <tbody id="lb-body"><tr><td colspan="6" style="text-align:center;padding:40px">⏳ Memuat...</td></tr></tbody>
      </table>
    </div>
  </div>`;

  window.changeLBMode = (m, el) => { lbMode=m; document.querySelectorAll('.filter-tab').forEach(t=>t.classList.remove('active')); el.classList.add('active'); loadLB(); };
  window.changeLBPeriod = (p, el) => { period=p; document.querySelectorAll('.filter-tab').forEach(t=>t.classList.remove('active')); el.classList.add('active'); loadLB(); };
  loadLB();
  setInterval(loadLB, 30000);
});

// ── Profile ───────────────────────────────────────────────────
routes['/profile'] = requireAuth(async () => {
  $('navbar').classList.remove('hidden');
  view().innerHTML = `<div class="container" style="max-width:700px"><p style="color:var(--text2)">⏳ Memuat profil...</p></div>`;
  try {
    const res = await api('GET', '/profile');
    const { user, spelling, speaking, history } = await res.json();
    view().innerHTML = `
    <div class="container" style="max-width:700px">
      <div class="card">
        <div style="display:flex;align-items:center;gap:20px;margin-bottom:24px">
          <div class="avatar-circle">${html(user.username.charAt(0).toUpperCase())}</div>
          <div><h2>${html(user.username)}</h2><p>Bergabung ${new Date(user.created_at).toLocaleDateString('id-ID')}</p></div>
        </div>
        <h3>📊 Statistik Spelling</h3>
        <div class="grid-4" style="margin:12px 0 24px">
          <div class="stat-box"><div class="stat-value">${spelling.total_score||0}</div><div class="stat-label">Total Score</div></div>
          <div class="stat-box"><div class="stat-value">${spelling.total_correct||0}</div><div class="stat-label">Kata Benar</div></div>
          <div class="stat-box"><div class="stat-value">${spelling.total_matches||0}</div><div class="stat-label">Match</div></div>
          <div class="stat-box"><div class="stat-value">${spelling.total_wins||0}</div><div class="stat-label">Menang</div></div>
        </div>
        <h3>🎙️ Statistik Speaking</h3>
        <div class="grid-4" style="margin:12px 0 24px">
          <div class="stat-box"><div class="stat-value">${speaking.total_score||0}</div><div class="stat-label">Total Score</div></div>
          <div class="stat-box"><div class="stat-value">${(speaking.avg_accuracy||0).toFixed(1)}%</div><div class="stat-label">Avg Akurasi</div></div>
          <div class="stat-box"><div class="stat-value">${speaking.total_tests||0}</div><div class="stat-label">Total Test</div></div>
          <div class="stat-box"><div class="stat-value">${speaking.highest_score||0}</div><div class="stat-label">Tertinggi</div></div>
        </div>
        ${history.length ? `<h3>📜 Riwayat Match</h3>
        <table class="lb-table"><thead><tr><th>Mode</th><th>Score</th><th>Benar</th><th>Salah</th><th>Tanggal</th></tr></thead>
        <tbody>${history.map(h=>`<tr><td><span class="badge badge-blue">${h.mode}</span></td><td>${h.score}</td><td>${h.correct_count}</td><td>${h.wrong_count}</td><td>${new Date(h.created_at).toLocaleDateString('id-ID')}</td></tr>`).join('')}</tbody></table>` : ''}
        <div style="margin-top:20px">
          <button class="btn btn-danger" onclick="logout()">🚪 Logout</button>
        </div>
      </div>
    </div>`;
  } catch { view().innerHTML = '<div class="container"><p style="color:var(--red)">Gagal memuat profil</p></div>'; }
});

// ── 404 / 500 ─────────────────────────────────────────────────
routes['/404'] = () => {
  view().innerHTML = `<div class="error-page"><div class="error-code">404</div><div class="error-msg">Halaman tidak ditemukan</div><p>Halaman yang kamu cari tidak ada atau telah dipindahkan.</p><br><button class="btn btn-primary" onclick="navigate('/dashboard')">Kembali ke Dashboard</button></div>`;
};
routes['/500'] = () => {
  view().innerHTML = `<div class="error-page"><div class="error-code">500</div><div class="error-msg">Terjadi kesalahan server</div><p>Maaf, terjadi kesalahan. Silakan coba lagi.</p><br><button class="btn btn-primary" onclick="navigate('/')">Kembali ke Beranda</button></div>`;
};

// ── Init ──────────────────────────────────────────────────────
window.addEventListener('load', () => {
  setTimeout(() => {
    $('loading-screen').style.display = 'none';
    const path = window.location.pathname || '/';
    if (App.token && App.user) {
      initSocket();
      $('navbar').classList.remove('hidden');
      $('nav-username').textContent = App.user.username;
    }
    render(path);
  }, 1200);
});
APPJS

log "Frontend generated"

# ════════════════════════════════════════════════════════════
hdr "STEP 9 — Generate Config Files"
# ════════════════════════════════════════════════════════════

# ── .env ─────────────────────────────────────────────────────
cat > $APP_DIR/.env << ENVFILE
# Server
NODE_ENV=production
PORT=3000

# Database
DB_HOST=localhost
DB_PORT=5432
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

# Redis
REDIS_URL=redis://:${REDIS_PASS}@localhost:6379
REDIS_PASS=${REDIS_PASS}

# JWT
JWT_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH}
JWT_EXPIRY=24h
SESSION_TTL=86400

# CORS
CORS_ORIGIN=http://${SERVER_IP}

# Ollama
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=mistral:7b-instruct

# Concurrency limits (VPS 8GB)
MAX_CONCURRENT_AI=2
MAX_CONCURRENT_TTS=2

# Logging
LOG_LEVEL=info
ENVFILE

# ── .env.example ─────────────────────────────────────────────
cat > $APP_DIR/.env.example << 'ENVEX'
NODE_ENV=production
PORT=3000
DB_HOST=localhost
DB_PORT=5432
DB_NAME=langcomp
DB_USER=langcomp_user
DB_PASS=your_db_password
REDIS_URL=redis://:your_redis_pass@localhost:6379
REDIS_PASS=your_redis_password
JWT_SECRET=your_jwt_secret_64chars
JWT_REFRESH_SECRET=your_refresh_secret
JWT_EXPIRY=24h
SESSION_TTL=86400
CORS_ORIGIN=http://your-server-ip
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=mistral:7b-instruct
MAX_CONCURRENT_AI=2
MAX_CONCURRENT_TTS=2
ENVEX

# ── ecosystem.config.js ───────────────────────────────────────
cat > $APP_DIR/ecosystem.config.js << 'PM2CFG'
module.exports = {
  apps: [
    {
      name: 'langcomp',
      script: 'server/index.js',
      cwd: '/app',
      instances: 2,
      exec_mode: 'cluster',
      watch: false,
      max_memory_restart: '1G',
      env: { NODE_ENV: 'production', PORT: 3000 },
      error_file: '/app/logs/pm2-error.log',
      out_file: '/app/logs/pm2-out.log',
      merge_logs: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      autorestart: true,
      restart_delay: 3000,
      max_restarts: 10,
      min_uptime: '5s',
      kill_timeout: 5000
    }
  ]
};
PM2CFG

log "Config files generated"

# ════════════════════════════════════════════════════════════
hdr "STEP 10 — Install npm Dependencies"
# ════════════════════════════════════════════════════════════
cd $APP_DIR
npm install --production 2>&1 | tail -5
log "npm packages installed"

# ════════════════════════════════════════════════════════════
hdr "STEP 11 — Setup PostgreSQL"
# ════════════════════════════════════════════════════════════
systemctl start postgresql
systemctl enable postgresql

# Create DB and user
sudo -u postgres psql << SQLCMDS
CREATE DATABASE ${DB_NAME};
CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
ALTER USER ${DB_USER} CREATEDB;
\c ${DB_NAME}
GRANT ALL ON SCHEMA public TO ${DB_USER};
SQLCMDS

log "PostgreSQL configured"

# ════════════════════════════════════════════════════════════
hdr "STEP 12 — Setup Redis"
# ════════════════════════════════════════════════════════════
# Set password
sed -i "s/# requirepass foobared/requirepass ${REDIS_PASS}/" /etc/redis/redis.conf
sed -i 's/bind 127.0.0.1 -::1/bind 127.0.0.1/' /etc/redis/redis.conf
systemctl restart redis-server
systemctl enable redis-server
log "Redis configured"

# ════════════════════════════════════════════════════════════
hdr "STEP 13 — Setup Nginx"
# ════════════════════════════════════════════════════════════
# Disable directory listing in nginx.conf
sed -i 's/# server_tokens off/server_tokens off/' /etc/nginx/nginx.conf
sed -i '/http {/a\\tautoindex off;' /etc/nginx/nginx.conf

cat > /etc/nginx/sites-available/langcomp << NGINXCFG
upstream langcomp_backend {
    least_conn;
    server 127.0.0.1:3000 fail_timeout=0;
    keepalive 32;
}

server {
    listen 80;
    server_name ${SERVER_IP} _;
    charset utf-8;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(self), camera=()" always;

    # No directory listing
    autoindex off;

    # Client limits
    client_max_body_size 15m;
    client_body_timeout 30s;
    client_header_timeout 30s;
    keepalive_timeout 65;

    # Gzip
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript;
    gzip_min_length 1000;
    gzip_comp_level 6;

    # Static files
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://langcomp_backend;
        proxy_cache_bypass \$http_upgrade;
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    # Socket.IO WebSocket
    location /socket.io/ {
        proxy_pass http://langcomp_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # API & SSE
    location /api/ {
        proxy_pass http://langcomp_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_buffering off;
    }

    # App
    location / {
        proxy_pass http://langcomp_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # Rate limit
    limit_req_zone \$binary_remote_addr zone=api:10m rate=30r/m;
    location /api/auth/ {
        limit_req zone=api burst=10 nodelay;
        proxy_pass http://langcomp_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINXCFG

ln -sf /etc/nginx/sites-available/langcomp /etc/nginx/sites-enabled/langcomp
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx && systemctl enable nginx
log "Nginx configured"

# ════════════════════════════════════════════════════════════
hdr "STEP 14 — Configure Firewall"
# ════════════════════════════════════════════════════════════
ufw --force enable
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 5432/tcp   # block postgres from outside
ufw deny 6379/tcp   # block redis from outside
ufw deny 3000/tcp   # block direct node access
ufw deny 11434/tcp  # block ollama from outside
log "Firewall configured (80, 443 open)"

# ════════════════════════════════════════════════════════════
hdr "STEP 15 — Wait for Whisper Download"
# ════════════════════════════════════════════════════════════
if kill -0 $WHISPER_PID 2>/dev/null; then
  info "Menunggu Whisper model download selesai..."
  wait $WHISPER_PID || true
fi
log "Whisper ready"

# ════════════════════════════════════════════════════════════
hdr "STEP 16 — Auto-Delete Temp Audio (Cron)"
# ════════════════════════════════════════════════════════════
(crontab -l 2>/dev/null; echo "*/30 * * * * find /app/audio/temp -type f -mmin +30 -delete") | crontab -
log "Temp audio cleanup cron set"

# ════════════════════════════════════════════════════════════
hdr "STEP 17 — Start All Services with PM2"
# ════════════════════════════════════════════════════════════
cd $APP_DIR
pm2 start ecosystem.config.js
pm2 save
pm2 startup systemd -u root --hp /root 2>/dev/null | bash 2>/dev/null || true
sleep 3
pm2 status
log "PM2 started"

# ════════════════════════════════════════════════════════════
hdr "STEP 18 — Initialize Database Schema"
# ════════════════════════════════════════════════════════════
# Trigger DB init via app startup (already done on boot)
sleep 2
# Verify connection
sudo -u postgres psql -d ${DB_NAME} -c "\dt" 2>/dev/null || warn "DB tables will be created on first request"
log "Database initialized"

# ════════════════════════════════════════════════════════════
hdr "SELESAI! 🎉"
# ════════════════════════════════════════════════════════════

# Save credentials
cat > /root/langcomp-credentials.txt << CREDS
╔══════════════════════════════════════════════════════════╗
║           LANGCOMP — INSTALLATION COMPLETE               ║
╠══════════════════════════════════════════════════════════╣
║  APP URL    : http://${SERVER_IP}                         
║  DB Name    : ${DB_NAME}                                  
║  DB User    : ${DB_USER}                                  
║  DB Pass    : ${DB_PASS}                                  
║  Redis Pass : ${REDIS_PASS}                               
║  JWT Secret : ${JWT_SECRET}                               
╠══════════════════════════════════════════════════════════╣
║  PM2 Commands:                                           ║
║    pm2 status          → Lihat status                   ║
║    pm2 logs langcomp   → Lihat logs                     ║
║    pm2 restart all     → Restart                        ║
║  Nginx: systemctl restart nginx                         ║
╠══════════════════════════════════════════════════════════╣
║  Credentials saved to: /root/langcomp-credentials.txt   ║
╚══════════════════════════════════════════════════════════╝
CREDS
chmod 600 /root/langcomp-credentials.txt

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║       ✅  LANGCOMP BERHASIL DIINSTALL!                   ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${CYAN}║  🌐 Akses Website: ${BOLD}http://${SERVER_IP}${NC}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${YELLOW}║  📁 Project Dir  : /app                                  ║${NC}"
echo -e "${BOLD}${YELLOW}║  🔐 Credentials  : /root/langcomp-credentials.txt        ║${NC}"
echo -e "${BOLD}${YELLOW}║  📊 PM2 Status   : pm2 status                            ║${NC}"
echo -e "${BOLD}${YELLOW}║  📋 Logs         : pm2 logs langcomp                     ║${NC}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Catatan: Ollama AI model mungkin masih diunduh di background.${NC}"
echo -e "${CYAN}Cek dengan: ${BOLD}ollama list${NC}"
echo ""
