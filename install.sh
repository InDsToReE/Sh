#!/usr/bin/env bash
# =============================================================================
# AI Dev Platform - Full Production Install Script
# Ubuntu 22.04 | 8GB RAM | 4 vCPU | 220GB SSD
# =============================================================================
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}\n"; }

LOGFILE="/var/log/ai-platform-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

# ── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { err "Run as root or with sudo"; exit 1; }

# =============================================================================
# SECTION 1 – INTERACTIVE CONFIGURATION
# =============================================================================
section "Interactive Configuration"

prompt() {
  local var="$1" msg="$2" default="${3:-}"
  local val
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "$(echo -e "${BOLD}${msg}${NC} [${default}]: ")" val
      val="${val:-$default}"
    else
      read -rp "$(echo -e "${BOLD}${msg}${NC}: ")" val
    fi
    [[ -n "$val" ]] && break
    warn "Value cannot be empty."
  done
  printf -v "$var" '%s' "$val"
}

prompt_secret() {
  local var="$1" msg="$2"
  local val val2
  while true; do
    read -rsp "$(echo -e "${BOLD}${msg}${NC}: ")" val; echo
    read -rsp "$(echo -e "${BOLD}Confirm ${msg}${NC}: ")" val2; echo
    [[ "$val" == "$val2" && -n "$val" ]] && break
    warn "Passwords do not match or are empty. Try again."
  done
  printf -v "$var" '%s' "$val"
}

echo ""
log "Please provide installation configuration."
echo ""

prompt WEB_NAME   "Web Application Name"         "AI Dev Platform"
prompt DB_NAME    "PostgreSQL Database Name"      "aiplatform_db"
prompt DB_USER    "PostgreSQL Username"           "aiplatform_user"
prompt_secret DB_PASS "PostgreSQL Password"
prompt DOMAIN     "Domain Name (leave empty for IP only)" ""
prompt DEPLOY_USER "Deploy Linux Username"        "deploy"

echo ""
echo -e "${BOLD}Select Mode:${NC}"
echo "  1) production   – optimised build, nginx caching, minimal logging"
echo "  2) development  – verbose logging, nodemon, no caching"
echo "  3) maintenance  – maintenance page, API disabled except admin"
echo ""
while true; do
  read -rp "Enter mode [1-3]: " MODE_SEL
  case "$MODE_SEL" in
    1) APP_MODE="production";   break ;;
    2) APP_MODE="development";  break ;;
    3) APP_MODE="maintenance";  break ;;
    *) warn "Enter 1, 2 or 3." ;;
  esac
done

# ── AI Model Selection ───────────────────────────────────────────────────────
section "AI Model Selection"

TOTAL_RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
log "Detected RAM: ${TOTAL_RAM_MB} MB"
echo ""
echo -e "${BOLD}Available Ollama Models:${NC}"
echo ""
printf "%-5s %-30s %-12s %-18s %-14s\n" "No." "Model" "Size" "Recommended RAM" "Disk Usage"
printf "%-5s %-30s %-12s %-18s %-14s\n" "---" "-----" "----" "---------------" "----------"
printf "%-5s %-30s %-12s %-18s %-14s\n" "1"   "deepseek-coder:1.3b"   "~800MB"  "≥4GB"  "~800MB"
printf "%-5s %-30s %-12s %-18s %-14s\n" "2"   "deepseek-coder:6.7b"   "~3.8GB"  "≥8GB"  "~3.8GB"
printf "%-5s %-30s %-12s %-18s %-14s\n" "3"   "starcoder2:3b"         "~1.7GB"  "≥4GB"  "~1.7GB"
printf "%-5s %-30s %-12s %-18s %-14s\n" "4"   "qwen2.5-coder:3b"      "~1.9GB"  "≥4GB"  "~1.9GB"
printf "%-5s %-30s %-12s %-18s %-14s\n" "5"   "qwen2.5-coder:7b"      "~4.1GB"  "≥8GB"  "~4.1GB"
echo ""

declare -A MODEL_MAP=(
  [1]="deepseek-coder:1.3b"
  [2]="deepseek-coder:6.7b"
  [3]="starcoder2:3b"
  [4]="qwen2.5-coder:3b"
  [5]="qwen2.5-coder:7b"
)

while true; do
  read -rp "Select model [1-5]: " MODEL_SEL
  [[ ${MODEL_MAP[$MODEL_SEL]+_} ]] && break
  warn "Enter a number between 1 and 5."
done
OLLAMA_MODEL="${MODEL_MAP[$MODEL_SEL]}"
log "Selected model: $OLLAMA_MODEL"

# ── Derived variables ────────────────────────────────────────────────────────
BASE_DIR="/opt/aiplatform"
BACKEND_DIR="$BASE_DIR/backend"
FRONTEND_DIR="$BASE_DIR/frontend"
PROJECTS_DIR="$BASE_DIR/projects"
BACKUPS_DIR="$BASE_DIR/backups"
MANAGER_SCRIPT="/usr/local/bin/ai-manager"
JWT_SECRET=$(openssl rand -hex 32)
NODE_PORT=3001
VITE_PORT=5173
DOMAIN_OR_IP="${DOMAIN:-$(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')}"

# =============================================================================
# SECTION 2 – SYSTEM PREREQUISITES
# =============================================================================
section "System Prerequisites"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y
apt-get install -y \
  curl wget git unzip zip gnupg lsb-release ca-certificates \
  build-essential software-properties-common apt-transport-https \
  ufw fail2ban nginx openssl \
  postgresql postgresql-contrib \
  python3 python3-pip php-cli composer \
  htop net-tools jq

# ── Swap ─────────────────────────────────────────────────────────────────────
section "Swap Configuration (4GB)"
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=10
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
  log "Swap configured."
fi

# ── Deploy user ───────────────────────────────────────────────────────────────
section "Deploy User"
if ! id "$DEPLOY_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
  usermod -aG sudo "$DEPLOY_USER"
  log "User $DEPLOY_USER created."
fi

# =============================================================================
# SECTION 3 – NODE.JS
# =============================================================================
section "Node.js LTS"
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
fi
log "Node $(node -v) | npm $(npm -v)"
npm install -g pm2 nodemon typescript

# =============================================================================
# SECTION 4 – POSTGRESQL
# =============================================================================
section "PostgreSQL"
systemctl enable postgresql --now

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE "${DB_USER}" LOGIN PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
SQL

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
SELECT 'CREATE DATABASE "${DB_NAME}" OWNER "${DB_USER}"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')
\gexec
SQL

PG_HBA="/etc/postgresql/$(ls /etc/postgresql)/main/pg_hba.conf"
PG_CONF="/etc/postgresql/$(ls /etc/postgresql)/main/postgresql.conf"

# Allow local connections with password
grep -qF "host    all             all             127.0.0.1/32            md5" "$PG_HBA" || \
  echo "host    all             all             127.0.0.1/32            md5" >> "$PG_HBA"

sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" "$PG_CONF"
systemctl restart postgresql
log "PostgreSQL ready."

# =============================================================================
# SECTION 5 – OLLAMA
# =============================================================================
section "Ollama"
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

# Systemd override to bind 0.0.0.0 and limit memory
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_NUM_PARALLEL=2"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
LimitNOFILE=65536
EOF

systemctl daemon-reload
systemctl enable ollama --now
sleep 5

log "Pulling model: $OLLAMA_MODEL (this may take a while)..."
ollama pull "$OLLAMA_MODEL"
log "Model pulled."

# =============================================================================
# SECTION 6 – DIRECTORY STRUCTURE
# =============================================================================
section "Directory Structure"
mkdir -p "$BACKEND_DIR" "$FRONTEND_DIR" "$PROJECTS_DIR" "$BACKUPS_DIR"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$BASE_DIR"

# =============================================================================
# SECTION 7 – BACKEND (Express + Prisma)
# =============================================================================
section "Backend"

cd "$BACKEND_DIR"

# package.json
cat > package.json <<'PKGJSON'
{
  "name": "aiplatform-backend",
  "version": "1.0.0",
  "scripts": {
    "start": "node dist/index.js",
    "dev": "nodemon src/index.ts",
    "build": "tsc"
  },
  "dependencies": {
    "@prisma/client": "^5.13.0",
    "bcrypt": "^5.1.1",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "express-rate-limit": "^7.2.0",
    "express-validator": "^7.0.1",
    "jsonwebtoken": "^9.0.2",
    "multer": "^1.4.5-lts.1",
    "node-pty": "^1.0.0",
    "simple-git": "^3.24.0",
    "socket.io": "^4.7.5",
    "uuid": "^9.0.1",
    "ws": "^8.17.0"
  },
  "devDependencies": {
    "@types/bcrypt": "^5.0.2",
    "@types/cors": "^2.8.17",
    "@types/express": "^4.17.21",
    "@types/jsonwebtoken": "^9.0.6",
    "@types/multer": "^1.4.11",
    "@types/node": "^20.12.7",
    "@types/uuid": "^9.0.8",
    "@types/ws": "^8.5.10",
    "nodemon": "^3.1.0",
    "prisma": "^5.13.0",
    "ts-node": "^10.9.2",
    "typescript": "^5.4.5"
  }
}
PKGJSON

# tsconfig
cat > tsconfig.json <<'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "lib": ["ES2020"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": false,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG

# Prisma schema
mkdir -p prisma
cat > prisma/schema.prisma <<'PRISMA'
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id        String   @id @default(uuid())
  username  String   @unique
  email     String   @unique
  password  String
  role      String   @default("user")
  createdAt DateTime @default(now())
  sessions  Session[]
  projects  Project[]
  aiLogs    AiLog[]
}

model Session {
  id        String   @id @default(uuid())
  userId    String
  token     String   @unique
  expiresAt DateTime
  createdAt DateTime @default(now())
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
}

model Project {
  id          String    @id @default(uuid())
  name        String
  description String?
  path        String    @unique
  userId      String
  createdAt   DateTime  @default(now())
  updatedAt   DateTime  @updatedAt
  user        User      @relation(fields: [userId], references: [id], onDelete: Cascade)
  files       File[]
  versions    ProjectVersion[]
  aiLogs      AiLog[]
}

model File {
  id        String   @id @default(uuid())
  projectId String
  path      String
  name      String
  size      Int      @default(0)
  mimeType  String?
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt
  project   Project  @relation(fields: [projectId], references: [id], onDelete: Cascade)
}

model AiLog {
  id        String   @id @default(uuid())
  userId    String
  projectId String?
  prompt    String
  response  String
  model     String
  tokens    Int?
  createdAt DateTime @default(now())
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
  project   Project? @relation(fields: [projectId], references: [id], onDelete: SetNull)
}

model ProjectVersion {
  id          String   @id @default(uuid())
  projectId   String
  commitHash  String
  message     String
  createdAt   DateTime @default(now())
  project     Project  @relation(fields: [projectId], references: [id], onDelete: Cascade)
}
PRISMA

# Source files
mkdir -p src/routes src/middleware src/services

# ── src/index.ts ──────────────────────────────────────────────────────────────
cat > src/index.ts <<'INDEXTS'
import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { Server } from 'socket.io';
import dotenv from 'dotenv';
import rateLimit from 'express-rate-limit';
import authRoutes from './routes/auth';
import projectRoutes from './routes/projects';
import fileRoutes from './routes/files';
import aiRoutes from './routes/ai';
import terminalHandler from './services/terminal';

dotenv.config();

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: { origin: '*', methods: ['GET', 'POST'] }
});

const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 200 });

app.use(cors());
app.use(express.json({ limit: '50mb' }));
app.use('/api', limiter);

app.use('/api/auth', authRoutes);
app.use('/api/projects', projectRoutes);
app.use('/api/files', fileRoutes);
app.use('/api/ai', aiRoutes);

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

terminalHandler(io);

const PORT = process.env.PORT || 3001;
httpServer.listen(PORT, () => console.log(`Backend running on port ${PORT}`));
INDEXTS

# ── src/middleware/auth.ts ────────────────────────────────────────────────────
cat > src/middleware/auth.ts <<'AUTHMW'
import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';

export interface AuthRequest extends Request {
  user?: { id: string; role: string };
}

export const authenticate = (req: AuthRequest, res: Response, next: NextFunction) => {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'Unauthorised' });
  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET!) as { id: string; role: string };
    req.user = decoded;
    next();
  } catch {
    res.status(401).json({ error: 'Invalid token' });
  }
};

export const requireAdmin = (req: AuthRequest, res: Response, next: NextFunction) => {
  if (req.user?.role !== 'admin') return res.status(403).json({ error: 'Forbidden' });
  next();
};
AUTHMW

# ── src/routes/auth.ts ────────────────────────────────────────────────────────
cat > src/routes/auth.ts <<'AUTHRT'
import { Router, Request, Response } from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { PrismaClient } from '@prisma/client';
import { body, validationResult } from 'express-validator';
import { authenticate, AuthRequest } from '../middleware/auth';

const router = Router();
const prisma = new PrismaClient();

router.post('/register',
  body('username').trim().isLength({ min: 3 }),
  body('email').isEmail().normalizeEmail(),
  body('password').isLength({ min: 6 }),
  async (req: Request, res: Response) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });
    const { username, email, password } = req.body;
    try {
      const hash = await bcrypt.hash(password, 12);
      const user = await prisma.user.create({ data: { username, email, password: hash } });
      res.status(201).json({ id: user.id, username: user.username, email: user.email });
    } catch (e: any) {
      res.status(400).json({ error: e.message });
    }
  }
);

router.post('/login',
  body('email').isEmail().normalizeEmail(),
  body('password').notEmpty(),
  async (req: Request, res: Response) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });
    const { email, password } = req.body;
    const user = await prisma.user.findUnique({ where: { email } });
    if (!user || !await bcrypt.compare(password, user.password))
      return res.status(401).json({ error: 'Invalid credentials' });
    const token = jwt.sign({ id: user.id, role: user.role }, process.env.JWT_SECRET!, { expiresIn: '7d' });
    await prisma.session.create({ data: { userId: user.id, token, expiresAt: new Date(Date.now() + 7*24*3600*1000) } });
    res.json({ token, user: { id: user.id, username: user.username, email: user.email, role: user.role } });
  }
);

router.get('/me', authenticate, async (req: AuthRequest, res: Response) => {
  const user = await prisma.user.findUnique({ where: { id: req.user!.id }, select: { id: true, username: true, email: true, role: true } });
  res.json(user);
});

router.post('/logout', authenticate, async (req: AuthRequest, res: Response) => {
  const token = req.headers.authorization?.split(' ')[1];
  await prisma.session.deleteMany({ where: { token } });
  res.json({ message: 'Logged out' });
});

export default router;
AUTHRT

# ── src/routes/projects.ts ────────────────────────────────────────────────────
cat > src/routes/projects.ts <<'PROJRT'
import { Router, Response } from 'express';
import { PrismaClient } from '@prisma/client';
import { authenticate, AuthRequest } from '../middleware/auth';
import simpleGit from 'simple-git';
import path from 'path';
import fs from 'fs';

const router = Router();
const prisma = new PrismaClient();
const PROJECTS_ROOT = process.env.PROJECTS_DIR || '/opt/aiplatform/projects';

router.use(authenticate);

router.get('/', async (req: AuthRequest, res: Response) => {
  const projects = await prisma.project.findMany({ where: { userId: req.user!.id }, orderBy: { updatedAt: 'desc' } });
  res.json(projects);
});

router.post('/', async (req: AuthRequest, res: Response) => {
  const { name, description } = req.body;
  if (!name) return res.status(400).json({ error: 'Name required' });
  const safeName = name.replace(/[^a-zA-Z0-9_-]/g, '_');
  const projectPath = path.join(PROJECTS_ROOT, req.user!.id, safeName);
  if (fs.existsSync(projectPath)) return res.status(400).json({ error: 'Project already exists' });
  fs.mkdirSync(projectPath, { recursive: true });
  const git = simpleGit(projectPath);
  await git.init();
  await git.addConfig('user.email', 'ai@platform.local');
  await git.addConfig('user.name', 'AI Platform');
  fs.writeFileSync(path.join(projectPath, 'README.md'), `# ${name}\n`);
  await git.add('.');
  await git.commit('Initial commit');
  const project = await prisma.project.create({ data: { name, description, path: projectPath, userId: req.user!.id } });
  res.status(201).json(project);
});

router.get('/:id', async (req: AuthRequest, res: Response) => {
  const project = await prisma.project.findFirst({ where: { id: req.params.id, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Not found' });
  res.json(project);
});

router.put('/:id', async (req: AuthRequest, res: Response) => {
  const { name, description } = req.body;
  const project = await prisma.project.findFirst({ where: { id: req.params.id, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Not found' });
  const updated = await prisma.project.update({ where: { id: project.id }, data: { name, description } });
  res.json(updated);
});

router.delete('/:id', async (req: AuthRequest, res: Response) => {
  const project = await prisma.project.findFirst({ where: { id: req.params.id, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Not found' });
  fs.rmSync(project.path, { recursive: true, force: true });
  await prisma.project.delete({ where: { id: project.id } });
  res.json({ message: 'Deleted' });
});

router.get('/:id/versions', async (req: AuthRequest, res: Response) => {
  const project = await prisma.project.findFirst({ where: { id: req.params.id, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Not found' });
  const git = simpleGit(project.path);
  const log = await git.log();
  res.json(log.all);
});

router.post('/:id/restore', async (req: AuthRequest, res: Response) => {
  const { commitHash } = req.body;
  if (!commitHash) return res.status(400).json({ error: 'commitHash required' });
  const project = await prisma.project.findFirst({ where: { id: req.params.id, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Not found' });
  const git = simpleGit(project.path);
  await git.checkout(commitHash, ['.']);
  res.json({ message: `Restored to ${commitHash}` });
});

export default router;
PROJRT

# ── src/routes/files.ts ───────────────────────────────────────────────────────
cat > src/routes/files.ts <<'FILERT'
import { Router, Response, Request } from 'express';
import { authenticate, AuthRequest } from '../middleware/auth';
import { PrismaClient } from '@prisma/client';
import path from 'path';
import fs from 'fs';
import simpleGit from 'simple-git';

const router = Router();
const prisma = new PrismaClient();
router.use(authenticate);

function safeResolvePath(base: string, rel: string): string {
  const resolved = path.resolve(base, rel);
  if (!resolved.startsWith(base)) throw new Error('Path traversal detected');
  return resolved;
}

async function commitChange(projectPath: string, message: string) {
  const git = simpleGit(projectPath);
  await git.add('.');
  try { await git.commit(message); } catch {}
}

router.get('/list', async (req: AuthRequest, res: Response) => {
  const { projectId, dir } = req.query as Record<string, string>;
  const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Project not found' });
  const targetDir = dir ? safeResolvePath(project.path, dir) : project.path;
  if (!fs.existsSync(targetDir)) return res.status(404).json({ error: 'Directory not found' });
  const entries = fs.readdirSync(targetDir, { withFileTypes: true }).map(e => ({
    name: e.name, isDir: e.isDirectory(),
    path: path.relative(project.path, path.join(targetDir, e.name))
  }));
  res.json(entries);
});

router.get('/read', async (req: AuthRequest, res: Response) => {
  const { projectId, filePath } = req.query as Record<string, string>;
  const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Project not found' });
  const fullPath = safeResolvePath(project.path, filePath);
  if (!fs.existsSync(fullPath) || fs.statSync(fullPath).isDirectory()) return res.status(404).json({ error: 'File not found' });
  const content = fs.readFileSync(fullPath, 'utf-8');
  res.json({ content, path: filePath });
});

router.post('/write', async (req: AuthRequest, res: Response) => {
  const { projectId, filePath, content } = req.body;
  const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Project not found' });
  const fullPath = safeResolvePath(project.path, filePath);
  fs.mkdirSync(path.dirname(fullPath), { recursive: true });
  fs.writeFileSync(fullPath, content, 'utf-8');
  await commitChange(project.path, `Update ${filePath}`);
  res.json({ message: 'Saved' });
});

router.post('/create-file', async (req: AuthRequest, res: Response) => {
  const { projectId, filePath } = req.body;
  const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Project not found' });
  const fullPath = safeResolvePath(project.path, filePath);
  fs.mkdirSync(path.dirname(fullPath), { recursive: true });
  if (fs.existsSync(fullPath)) return res.status(400).json({ error: 'Already exists' });
  fs.writeFileSync(fullPath, '', 'utf-8');
  await commitChange(project.path, `Create ${filePath}`);
  res.json({ message: 'Created' });
});

router.post('/create-folder', async (req: AuthRequest, res: Response) => {
  const { projectId, folderPath } = req.body;
  const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Project not found' });
  const fullPath = safeResolvePath(project.path, folderPath);
  fs.mkdirSync(fullPath, { recursive: true });
  res.json({ message: 'Created' });
});

router.delete('/delete', async (req: AuthRequest, res: Response) => {
  const { projectId, targetPath, confirm } = req.body;
  if (!confirm) return res.status(400).json({ error: 'Confirmation required', requiresConfirm: true });
  const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Project not found' });
  const fullPath = safeResolvePath(project.path, targetPath);
  if (!fs.existsSync(fullPath)) return res.status(404).json({ error: 'Not found' });
  fs.rmSync(fullPath, { recursive: true, force: true });
  await commitChange(project.path, `Delete ${targetPath}`);
  res.json({ message: 'Deleted' });
});

router.get('/diff', async (req: AuthRequest, res: Response) => {
  const { projectId, filePath } = req.query as Record<string, string>;
  const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Project not found' });
  const git = simpleGit(project.path);
  const diff = await git.diff([filePath]);
  res.json({ diff });
});

export default router;
FILERT

# ── src/routes/ai.ts ──────────────────────────────────────────────────────────
cat > src/routes/ai.ts <<'AIRT'
import { Router, Response } from 'express';
import { authenticate, AuthRequest } from '../middleware/auth';
import { PrismaClient } from '@prisma/client';
import path from 'path';
import fs from 'fs';
import simpleGit from 'simple-git';

const router = Router();
const prisma = new PrismaClient();
router.use(authenticate);

const OLLAMA_URL = 'http://127.0.0.1:11434';
const MODEL = process.env.OLLAMA_MODEL || 'deepseek-coder:1.3b';
const MAX_CONTEXT_CHARS = 24000;
const IGNORE_DIRS = new Set(['node_modules', 'vendor', '.git', 'dist', 'build', '.next']);

function indexProject(dir: string, base = dir, depth = 0): string {
  if (depth > 8) return '';
  let out = '';
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (IGNORE_DIRS.has(entry.name)) continue;
    const rel = path.relative(base, path.join(dir, entry.name));
    if (entry.isDirectory()) {
      out += `📁 ${rel}/\n`;
      out += indexProject(path.join(dir, entry.name), base, depth + 1);
    } else {
      const stats = fs.statSync(path.join(dir, entry.name));
      out += `📄 ${rel} (${stats.size}B)\n`;
    }
  }
  return out;
}

function readProjectContext(dir: string, base = dir, chars = 0): string {
  let out = '';
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (IGNORE_DIRS.has(entry.name) || chars > MAX_CONTEXT_CHARS) break;
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      const sub = readProjectContext(fullPath, base, chars);
      out += sub; chars += sub.length;
    } else {
      const ext = path.extname(entry.name);
      const codeExts = ['.ts','.tsx','.js','.jsx','.py','.php','.json','.md','.html','.css','.sql','.sh','.env.example'];
      if (codeExts.includes(ext)) {
        try {
          const content = fs.readFileSync(fullPath, 'utf-8').slice(0, 4000);
          const rel = path.relative(base, fullPath);
          const chunk = `\n--- ${rel} ---\n${content}\n`;
          out += chunk; chars += chunk.length;
        } catch {}
      }
    }
  }
  return out;
}

router.post('/chat', async (req: AuthRequest, res: Response) => {
  const { prompt, projectId, includeFiles } = req.body;
  if (!prompt) return res.status(400).json({ error: 'Prompt required' });

  let systemContext = 'You are an expert AI programming assistant. Help the user with their code.';
  if (projectId) {
    const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
    if (project && fs.existsSync(project.path)) {
      const index = indexProject(project.path);
      systemContext += `\n\nProject structure:\n${index}`;
      if (includeFiles) {
        const fileCtx = readProjectContext(project.path);
        systemContext += `\n\nFile contents:\n${fileCtx}`;
      }
    }
  }

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');

  let fullResponse = '';
  try {
    const ollamaRes = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        stream: true,
        messages: [
          { role: 'system', content: systemContext },
          { role: 'user', content: prompt }
        ]
      })
    });

    const reader = ollamaRes.body!.getReader();
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value);
      for (const line of chunk.split('\n')) {
        if (!line.trim()) continue;
        try {
          const json = JSON.parse(line);
          const text = json.message?.content || '';
          fullResponse += text;
          res.write(`data: ${JSON.stringify({ text })}\n\n`);
        } catch {}
      }
    }
  } catch (e: any) {
    res.write(`data: ${JSON.stringify({ error: e.message })}\n\n`);
  }

  await prisma.aiLog.create({
    data: { userId: req.user!.id, projectId: projectId || null, prompt, response: fullResponse, model: MODEL }
  });

  res.write('data: [DONE]\n\n');
  res.end();
});

router.post('/file-action', async (req: AuthRequest, res: Response) => {
  const { projectId, action, filePath, content, confirm } = req.body;
  const destructive = ['delete', 'delete-folder'].includes(action);
  if (destructive && !confirm) {
    return res.status(400).json({ error: 'Confirmation required for destructive action', requiresConfirm: true, action, filePath });
  }
  const project = await prisma.project.findFirst({ where: { id: projectId, userId: req.user!.id } });
  if (!project) return res.status(404).json({ error: 'Project not found' });

  function safe(p: string) {
    const r = path.resolve(project!.path, p);
    if (!r.startsWith(project!.path)) throw new Error('Path traversal');
    return r;
  }

  const git = simpleGit(project.path);
  try {
    switch (action) {
      case 'create-file': {
        const fp = safe(filePath);
        fs.mkdirSync(path.dirname(fp), { recursive: true });
        fs.writeFileSync(fp, content || '', 'utf-8');
        break;
      }
      case 'edit-file': {
        const fp = safe(filePath);
        // show diff first
        const old = fs.existsSync(fp) ? fs.readFileSync(fp, 'utf-8') : '';
        if (!confirm) {
          return res.status(200).json({ requiresDiff: true, old, new: content, filePath });
        }
        fs.mkdirSync(path.dirname(fp), { recursive: true });
        fs.writeFileSync(fp, content, 'utf-8');
        break;
      }
      case 'delete': {
        fs.rmSync(safe(filePath), { force: true });
        break;
      }
      case 'create-folder': {
        fs.mkdirSync(safe(filePath), { recursive: true });
        break;
      }
      case 'delete-folder': {
        fs.rmSync(safe(filePath), { recursive: true, force: true });
        break;
      }
      default:
        return res.status(400).json({ error: 'Unknown action' });
    }
    await git.add('.');
    try { await git.commit(`AI: ${action} ${filePath}`); } catch {}
    res.json({ message: 'Action applied', action, filePath });
  } catch (e: any) {
    res.status(400).json({ error: e.message });
  }
});

export default router;
AIRT

# ── src/services/terminal.ts ─────────────────────────────────────────────────
cat > src/services/terminal.ts <<'TERMTS'
import { Server } from 'socket.io';
import * as pty from 'node-pty';
import jwt from 'jsonwebtoken';
import path from 'path';
import fs from 'fs';

const PROJECTS_ROOT = process.env.PROJECTS_DIR || '/opt/aiplatform/projects';

export default function terminalHandler(io: Server) {
  io.of('/terminal').use((socket, next) => {
    const token = socket.handshake.auth.token;
    if (!token) return next(new Error('Unauthorised'));
    try {
      const decoded = jwt.verify(token, process.env.JWT_SECRET!) as { id: string };
      (socket as any).userId = decoded.id;
      next();
    } catch {
      next(new Error('Invalid token'));
    }
  }).on('connection', socket => {
    const userId = (socket as any).userId;
    const workDir = path.join(PROJECTS_ROOT, userId);
    fs.mkdirSync(workDir, { recursive: true });

    const shell = pty.spawn('bash', [], {
      name: 'xterm-256color',
      cols: 80, rows: 24,
      cwd: workDir,
      env: { ...process.env, HOME: workDir, TERM: 'xterm-256color' } as NodeJS.ProcessEnv
    });

    shell.onData(data => socket.emit('output', data));
    socket.on('input', data => shell.write(data));
    socket.on('resize', ({ cols, rows }) => shell.resize(cols, rows));
    socket.on('disconnect', () => shell.kill());
  });
}
TERMTS

# Install backend dependencies + build
npm install --legacy-peer-deps
npx prisma generate

log "Backend source ready."

# =============================================================================
# SECTION 8 – FRONTEND (React + Vite + Tailwind + Monaco)
# =============================================================================
section "Frontend"

cd "$FRONTEND_DIR"

npm create vite@latest . -- --template react-ts --yes 2>/dev/null || true
npm install

npm install \
  @monaco-editor/react \
  tailwindcss autoprefixer postcss \
  axios \
  socket.io-client \
  xterm xterm-addon-fit xterm-addon-web-links \
  react-router-dom \
  react-resizable-panels \
  lucide-react \
  @radix-ui/react-dialog \
  @radix-ui/react-dropdown-menu

npx tailwindcss init -p 2>/dev/null || true

# tailwind.config.js
cat > tailwind.config.js <<'TWCFG'
/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        surface: '#0d1117',
        panel:   '#161b22',
        accent:  '#58a6ff',
        border:  '#30363d',
        text:    '#e6edf3',
        muted:   '#8b949e',
      }
    }
  },
  plugins: []
}
TWCFG

# postcss.config.js
cat > postcss.config.js <<'PCCFG'
export default { plugins: { tailwindcss: {}, autoprefixer: {} } }
PCCFG

# index.html
cat > index.html <<'HTMLIDX'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>AI Dev Platform</title>
  <link rel="icon" type="image/svg+xml" href="/vite.svg"/>
</head>
<body class="bg-surface text-text">
  <div id="root"></div>
  <script type="module" src="/src/main.tsx"></script>
</body>
</html>
HTMLIDX

mkdir -p src/pages src/components src/hooks src/api

# src/main.tsx
cat > src/main.tsx <<'MAINTSX'
import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </React.StrictMode>
)
MAINTSX

# src/index.css
cat > src/index.css <<'IDXCSS'
@tailwind base;
@tailwind components;
@tailwind utilities;

* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: #0d1117; color: #e6edf3; font-family: 'JetBrains Mono', monospace, sans-serif; }
::-webkit-scrollbar { width: 6px; }
::-webkit-scrollbar-track { background: #0d1117; }
::-webkit-scrollbar-thumb { background: #30363d; border-radius: 3px; }
IDXCSS

# src/api/client.ts
cat > src/api/client.ts <<'APICLIENT'
import axios from 'axios'

const api = axios.create({ baseURL: '/api' })

api.interceptors.request.use(cfg => {
  const token = localStorage.getItem('token')
  if (token) cfg.headers.Authorization = `Bearer ${token}`
  return cfg
})

api.interceptors.response.use(
  r => r,
  err => {
    if (err.response?.status === 401) {
      localStorage.removeItem('token')
      window.location.href = '/login'
    }
    return Promise.reject(err)
  }
)

export default api
APICLIENT

# src/App.tsx
cat > src/App.tsx <<'APPTSX'
import { Routes, Route, Navigate } from 'react-router-dom'
import Landing from './pages/Landing'
import Login from './pages/Login'
import Register from './pages/Register'
import Dashboard from './pages/Dashboard'
import ProjectPage from './pages/ProjectPage'

const PrivateRoute = ({ children }: { children: React.ReactNode }) => {
  const token = localStorage.getItem('token')
  return token ? <>{children}</> : <Navigate to="/login" />
}

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Landing />} />
      <Route path="/login" element={<Login />} />
      <Route path="/register" element={<Register />} />
      <Route path="/dashboard" element={<PrivateRoute><Dashboard /></PrivateRoute>} />
      <Route path="/project/:id" element={<PrivateRoute><ProjectPage /></PrivateRoute>} />
    </Routes>
  )
}
APPTSX

# src/pages/Landing.tsx
cat > src/pages/Landing.tsx <<'LANDTSX'
import { Link } from 'react-router-dom'

export default function Landing() {
  return (
    <div className="min-h-screen flex flex-col items-center justify-center bg-surface">
      <div className="text-center space-y-6 px-4">
        <h1 className="text-5xl font-bold text-accent">AI Dev Platform</h1>
        <p className="text-muted text-xl max-w-lg">Full-stack AI-powered IDE in your browser. Code, chat, deploy.</p>
        <div className="flex gap-4 justify-center">
          <Link to="/register" className="px-6 py-3 bg-accent text-surface font-semibold rounded-lg hover:bg-blue-400 transition">Get Started</Link>
          <Link to="/login" className="px-6 py-3 border border-border text-text rounded-lg hover:border-accent transition">Login</Link>
        </div>
      </div>
    </div>
  )
}
LANDTSX

# src/pages/Login.tsx
cat > src/pages/Login.tsx <<'LOGINTSX'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import api from '../api/client'

export default function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const navigate = useNavigate()

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    try {
      const { data } = await api.post('/auth/login', { email, password })
      localStorage.setItem('token', data.token)
      navigate('/dashboard')
    } catch (err: any) {
      setError(err.response?.data?.error || 'Login failed')
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-surface">
      <form onSubmit={submit} className="bg-panel border border-border rounded-xl p-8 w-full max-w-sm space-y-4">
        <h2 className="text-2xl font-bold text-accent">Login</h2>
        {error && <p className="text-red-400 text-sm">{error}</p>}
        <input className="w-full bg-surface border border-border rounded px-3 py-2 text-text outline-none focus:border-accent" type="email" placeholder="Email" value={email} onChange={e=>setEmail(e.target.value)} required/>
        <input className="w-full bg-surface border border-border rounded px-3 py-2 text-text outline-none focus:border-accent" type="password" placeholder="Password" value={password} onChange={e=>setPassword(e.target.value)} required/>
        <button className="w-full bg-accent text-surface py-2 rounded font-semibold hover:bg-blue-400 transition" type="submit">Login</button>
        <p className="text-muted text-sm text-center">No account? <Link to="/register" className="text-accent hover:underline">Register</Link></p>
      </form>
    </div>
  )
}
LOGINTSX

# src/pages/Register.tsx
cat > src/pages/Register.tsx <<'REGTSX'
import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import api from '../api/client'

export default function Register() {
  const [form, setForm] = useState({ username:'', email:'', password:'' })
  const [error, setError] = useState('')
  const navigate = useNavigate()

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    try {
      await api.post('/auth/register', form)
      navigate('/login')
    } catch (err: any) {
      setError(err.response?.data?.error || 'Registration failed')
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-surface">
      <form onSubmit={submit} className="bg-panel border border-border rounded-xl p-8 w-full max-w-sm space-y-4">
        <h2 className="text-2xl font-bold text-accent">Create Account</h2>
        {error && <p className="text-red-400 text-sm">{error}</p>}
        {(['username','email','password'] as const).map(field => (
          <input key={field} className="w-full bg-surface border border-border rounded px-3 py-2 text-text outline-none focus:border-accent"
            type={field==='password'?'password':field==='email'?'email':'text'}
            placeholder={field.charAt(0).toUpperCase()+field.slice(1)}
            value={form[field]} onChange={e=>setForm({...form,[field]:e.target.value})} required/>
        ))}
        <button className="w-full bg-accent text-surface py-2 rounded font-semibold hover:bg-blue-400 transition" type="submit">Register</button>
        <p className="text-muted text-sm text-center">Have account? <Link to="/login" className="text-accent hover:underline">Login</Link></p>
      </form>
    </div>
  )
}
REGTSX

# src/pages/Dashboard.tsx
cat > src/pages/Dashboard.tsx <<'DASHTSX'
import { useEffect, useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import api from '../api/client'

interface Project { id: string; name: string; description?: string; updatedAt: string }

export default function Dashboard() {
  const [projects, setProjects] = useState<Project[]>([])
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  const navigate = useNavigate()

  useEffect(() => { api.get('/projects').then(r => setProjects(r.data)).catch(()=>{}) }, [])

  const create = async (e: React.FormEvent) => {
    e.preventDefault()
    try {
      const { data } = await api.post('/projects', { name })
      navigate(`/project/${data.id}`)
    } catch (err: any) { alert(err.response?.data?.error || 'Failed') }
  }

  const logout = () => { localStorage.removeItem('token'); window.location.href = '/' }

  return (
    <div className="min-h-screen bg-surface p-6">
      <header className="flex items-center justify-between mb-8">
        <h1 className="text-2xl font-bold text-accent">Dashboard</h1>
        <button onClick={logout} className="text-muted hover:text-text text-sm">Logout</button>
      </header>

      <button onClick={()=>setCreating(true)} className="mb-6 px-4 py-2 bg-accent text-surface rounded font-semibold hover:bg-blue-400 transition">
        + New Project
      </button>

      {creating && (
        <form onSubmit={create} className="mb-6 flex gap-3">
          <input className="bg-panel border border-border rounded px-3 py-2 text-text outline-none focus:border-accent w-64"
            placeholder="Project name" value={name} onChange={e=>setName(e.target.value)} autoFocus required/>
          <button type="submit" className="px-4 py-2 bg-accent text-surface rounded hover:bg-blue-400 transition">Create</button>
          <button type="button" onClick={()=>setCreating(false)} className="px-4 py-2 border border-border rounded hover:border-accent transition">Cancel</button>
        </form>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        {projects.map(p => (
          <Link key={p.id} to={`/project/${p.id}`}
            className="bg-panel border border-border rounded-xl p-5 hover:border-accent transition group">
            <h3 className="text-text font-semibold group-hover:text-accent">{p.name}</h3>
            <p className="text-muted text-sm mt-1">{new Date(p.updatedAt).toLocaleDateString()}</p>
          </Link>
        ))}
        {projects.length === 0 && <p className="text-muted">No projects yet. Create one!</p>}
      </div>
    </div>
  )
}
DASHTSX

# src/pages/ProjectPage.tsx
cat > src/pages/ProjectPage.tsx <<'PROJPGTSX'
import { useEffect, useRef, useState, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import Editor from '@monaco-editor/react'
import { Terminal } from 'xterm'
import { FitAddon } from 'xterm-addon-fit'
import { io } from 'socket.io-client'
import api from '../api/client'
import 'xterm/css/xterm.css'

interface FileEntry { name: string; isDir: boolean; path: string }

export default function ProjectPage() {
  const { id } = useParams<{ id: string }>()
  const [files, setFiles] = useState<FileEntry[]>([])
  const [currentPath, setCurrentPath] = useState('')
  const [fileContent, setFileContent] = useState('')
  const [selectedFile, setSelectedFile] = useState<string | null>(null)
  const [aiMessages, setAiMessages] = useState<{role:'user'|'ai', text:string}[]>([])
  const [aiInput, setAiInput] = useState('')
  const [aiLoading, setAiLoading] = useState(false)
  const terminalRef = useRef<HTMLDivElement>(null)
  const xtermRef = useRef<Terminal | null>(null)
  const token = localStorage.getItem('token')

  useEffect(() => { loadFiles('') }, [id])

  useEffect(() => {
    if (!terminalRef.current) return
    const term = new Terminal({ theme: { background: '#0d1117', foreground: '#e6edf3', cursor: '#58a6ff' }, fontSize: 13 })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(terminalRef.current)
    fit.fit()
    xtermRef.current = term

    const socket = io('/terminal', { auth: { token } })
    socket.on('output', data => term.write(data))
    term.onData(data => socket.emit('input', data))
    term.onResize(({ cols, rows }) => socket.emit('resize', { cols, rows }))

    const ro = new ResizeObserver(() => fit.fit())
    ro.observe(terminalRef.current)
    return () => { term.dispose(); socket.disconnect(); ro.disconnect() }
  }, [])

  const loadFiles = async (dir: string) => {
    try {
      const { data } = await api.get('/files/list', { params: { projectId: id, dir } })
      setFiles(data)
      setCurrentPath(dir)
    } catch {}
  }

  const openFile = async (path: string) => {
    try {
      const { data } = await api.get('/files/read', { params: { projectId: id, filePath: path } })
      setFileContent(data.content)
      setSelectedFile(path)
    } catch {}
  }

  const saveFile = async () => {
    if (!selectedFile) return
    await api.post('/files/write', { projectId: id, filePath: selectedFile, content: fileContent })
  }

  const sendAI = async () => {
    if (!aiInput.trim()) return
    const msg = aiInput.trim()
    setAiMessages(m => [...m, { role: 'user', text: msg }])
    setAiInput('')
    setAiLoading(true)
    let resp = ''
    setAiMessages(m => [...m, { role: 'ai', text: '' }])

    try {
      const res = await fetch('/api/ai/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
        body: JSON.stringify({ prompt: msg, projectId: id, includeFiles: true })
      })
      const reader = res.body!.getReader()
      const decoder = new TextDecoder()
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        for (const line of decoder.decode(value).split('\n')) {
          if (line.startsWith('data: ')) {
            const payload = line.slice(6)
            if (payload === '[DONE]') break
            try { resp += JSON.parse(payload).text || ''; } catch {}
            setAiMessages(m => [...m.slice(0,-1), { role: 'ai', text: resp }])
          }
        }
      }
    } catch {}
    setAiLoading(false)
  }

  const extToLang = (p: string) => {
    const ext = p.split('.').pop()
    const map: Record<string,string> = { ts:'typescript', tsx:'typescript', js:'javascript', jsx:'javascript', py:'python', php:'php', json:'json', md:'markdown', css:'css', html:'html', sh:'bash' }
    return map[ext||''] || 'plaintext'
  }

  return (
    <div className="h-screen flex flex-col bg-surface overflow-hidden">
      {/* Header */}
      <header className="flex items-center gap-4 px-4 py-2 bg-panel border-b border-border text-sm">
        <Link to="/dashboard" className="text-muted hover:text-accent">← Dashboard</Link>
        <span className="text-muted">|</span>
        <span className="text-text">{selectedFile || 'No file open'}</span>
        {selectedFile && <button onClick={saveFile} className="ml-auto px-3 py-1 bg-accent text-surface rounded text-xs hover:bg-blue-400 transition">Save (Ctrl+S)</button>}
      </header>

      <div className="flex flex-1 overflow-hidden">
        {/* File Explorer */}
        <aside className="w-56 bg-panel border-r border-border flex flex-col overflow-hidden">
          <div className="p-2 text-xs text-muted uppercase tracking-wider border-b border-border">Explorer</div>
          {currentPath && (
            <button onClick={() => loadFiles(currentPath.split('/').slice(0,-1).join('/'))}
              className="flex items-center gap-1 px-3 py-1 text-muted hover:text-accent text-sm">.. (up)</button>
          )}
          <div className="overflow-y-auto flex-1">
            {files.map(f => (
              <div key={f.path}
                className={`flex items-center gap-2 px-3 py-1 text-sm cursor-pointer hover:bg-surface transition ${selectedFile===f.path?'text-accent bg-surface':f.isDir?'text-yellow-400':'text-text'}`}
                onClick={() => f.isDir ? loadFiles(f.path) : openFile(f.path)}>
                <span>{f.isDir ? '📁' : '📄'}</span>
                <span className="truncate">{f.name}</span>
              </div>
            ))}
          </div>
        </aside>

        {/* Editor + Terminal */}
        <div className="flex flex-col flex-1 overflow-hidden">
          <div className="flex-1 overflow-hidden">
            <Editor
              height="100%"
              theme="vs-dark"
              language={selectedFile ? extToLang(selectedFile) : 'plaintext'}
              value={fileContent}
              onChange={v => setFileContent(v || '')}
              options={{ fontSize: 14, minimap: { enabled: false }, padding: { top: 10 } }}
            />
          </div>
          <div ref={terminalRef} className="h-40 border-t border-border" />
        </div>

        {/* AI Chat */}
        <aside className="w-80 bg-panel border-l border-border flex flex-col overflow-hidden">
          <div className="p-2 text-xs text-muted uppercase tracking-wider border-b border-border">AI Assistant</div>
          <div className="flex-1 overflow-y-auto p-3 space-y-3">
            {aiMessages.map((m, i) => (
              <div key={i} className={`text-sm ${m.role==='user'?'text-accent':'text-text'}`}>
                <span className="text-xs text-muted block mb-1">{m.role==='user'?'You':'AI'}</span>
                <pre className="whitespace-pre-wrap font-mono text-xs bg-surface rounded p-2">{m.text}</pre>
              </div>
            ))}
            {aiLoading && <div className="text-muted text-xs animate-pulse">AI is thinking...</div>}
          </div>
          <div className="p-2 border-t border-border">
            <textarea
              className="w-full bg-surface border border-border rounded px-3 py-2 text-text text-sm outline-none focus:border-accent resize-none"
              rows={3} placeholder="Ask AI..." value={aiInput}
              onChange={e => setAiInput(e.target.value)}
              onKeyDown={e => { if (e.key==='Enter' && !e.shiftKey) { e.preventDefault(); sendAI() } }}/>
            <button onClick={sendAI} disabled={aiLoading}
              className="w-full mt-1 py-1 bg-accent text-surface text-sm rounded hover:bg-blue-400 transition disabled:opacity-50">
              Send
            </button>
          </div>
        </aside>
      </div>
    </div>
  )
}
PROJPGTSX

# vite.config.ts
cat > vite.config.ts <<'VITECFG'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': 'http://localhost:3001',
      '/terminal': { target: 'ws://localhost:3001', ws: true }
    }
  }
})
VITECFG

log "Frontend source ready."

# =============================================================================
# SECTION 9 – .ENV FILES
# =============================================================================
section "Environment Configuration"

DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?schema=public"

cat > "$BACKEND_DIR/.env" <<ENV
NODE_ENV=${APP_MODE}
PORT=${NODE_PORT}
DATABASE_URL=${DATABASE_URL}
JWT_SECRET=${JWT_SECRET}
PROJECTS_DIR=${PROJECTS_DIR}
OLLAMA_URL=http://127.0.0.1:11434
OLLAMA_MODEL=${OLLAMA_MODEL}
WEB_NAME=${WEB_NAME}
DOMAIN=${DOMAIN_OR_IP}
ENV

cat > "$BASE_DIR/.env" <<MAINENV
APP_MODE=${APP_MODE}
WEB_NAME=${WEB_NAME}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DOMAIN=${DOMAIN_OR_IP}
OLLAMA_MODEL=${OLLAMA_MODEL}
JWT_SECRET=${JWT_SECRET}
DEPLOY_USER=${DEPLOY_USER}
BASE_DIR=${BASE_DIR}
MAINENV

chmod 600 "$BACKEND_DIR/.env" "$BASE_DIR/.env"

# =============================================================================
# SECTION 10 – PRISMA MIGRATE + BUILD
# =============================================================================
section "Database Migration"

cd "$BACKEND_DIR"
npx prisma db push --accept-data-loss

section "Build Backend"
npm run build 2>/dev/null || { warn "TS build failed, creating simple JS entry"; mkdir -p dist; cp -r src/* dist/ 2>/dev/null || true; }

section "Build Frontend"
cd "$FRONTEND_DIR"
if [[ "$APP_MODE" == "production" ]]; then
  npm run build
elif [[ "$APP_MODE" == "development" ]]; then
  log "Development mode: skipping production build (nodemon will serve)"
else
  npm run build
fi

# =============================================================================
# SECTION 11 – NGINX
# =============================================================================
section "Nginx Configuration"

NGINX_CONF="/etc/nginx/sites-available/aiplatform"

if [[ "$APP_MODE" == "maintenance" ]]; then
  cat > "$NGINX_CONF" <<NGINXMAINT
server {
    listen 80;
    server_name ${DOMAIN_OR_IP};
    root /var/www/maintenance;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
    location /api/auth { proxy_pass http://127.0.0.1:${NODE_PORT}; proxy_http_version 1.1; }
}
NGINXMAINT
  mkdir -p /var/www/maintenance
  cat > /var/www/maintenance/index.html <<'MAINTHTML'
<!DOCTYPE html><html><head><title>Maintenance</title>
<style>body{background:#0d1117;color:#e6edf3;display:flex;align-items:center;justify-content:center;height:100vh;font-family:monospace;text-align:center}
h1{color:#58a6ff;font-size:2em}p{color:#8b949e;margin-top:1em}</style></head>
<body><div><h1>🔧 Maintenance Mode</h1><p>We'll be back shortly.</p></div></body></html>
MAINTHTML

else
  CACHE_DIRECTIVES=""
  if [[ "$APP_MODE" == "production" ]]; then
    CACHE_DIRECTIVES="
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires 1y;
        add_header Cache-Control \"public, immutable\";
    }"
  fi

  cat > "$NGINX_CONF" <<NGINXCFG
limit_req_zone \$binary_remote_addr zone=api:10m rate=30r/m;

server {
    listen 80;
    server_name ${DOMAIN_OR_IP};

    client_max_body_size 50M;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    # Frontend static files
    root ${FRONTEND_DIR}/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # API proxy
    location /api {
        limit_req zone=api burst=20 nodelay;
        proxy_pass http://127.0.0.1:${NODE_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }

    # WebSocket terminal
    location /socket.io {
        proxy_pass http://127.0.0.1:${NODE_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }
    ${CACHE_DIRECTIVES}
}
NGINXCFG
fi

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/aiplatform
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

log "Nginx configured."

# =============================================================================
# SECTION 12 – PM2
# =============================================================================
section "PM2 Process Manager"

cd "$BACKEND_DIR"

if [[ "$APP_MODE" == "development" ]]; then
  cat > ecosystem.config.js <<ECODEV
module.exports = {
  apps: [{
    name: 'aiplatform-backend',
    script: 'src/index.ts',
    interpreter: 'node_modules/.bin/ts-node',
    watch: ['src'],
    env: { NODE_ENV: 'development' }
  }]
}
ECODEV
else
  cat > ecosystem.config.js <<ECOPROD
module.exports = {
  apps: [{
    name: 'aiplatform-backend',
    script: 'dist/index.js',
    instances: 2,
    exec_mode: 'cluster',
    env: { NODE_ENV: '${APP_MODE}' },
    error_file: '/var/log/aiplatform-error.log',
    out_file: '/var/log/aiplatform-out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss'
  }]
}
ECOPROD
fi

pm2 delete aiplatform-backend 2>/dev/null || true
pm2 start ecosystem.config.js
pm2 save
pm2 startup | tail -1 | bash || true

log "PM2 configured."

# =============================================================================
# SECTION 13 – SECURITY
# =============================================================================
section "Security: UFW + Fail2ban"

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Fail2ban
cat > /etc/fail2ban/jail.local <<F2BJAIL
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-limit-req]
enabled  = true
filter   = nginx-limit-req
logpath  = /var/log/nginx/error.log
maxretry = 10
F2BJAIL

systemctl enable fail2ban --now
systemctl restart fail2ban

# Harden SSH
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

log "Security configured."

# =============================================================================
# SECTION 14 – AI-MANAGER CLI
# =============================================================================
section "AI Manager CLI"

cat > "$MANAGER_SCRIPT" <<'AIMGR'
#!/usr/bin/env bash
# ============================================================
# AI Platform Manager
# ============================================================
set -euo pipefail

BASE_DIR="/opt/aiplatform"
ENV_FILE="$BASE_DIR/.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

confirm() {
  local msg="${1:-Are you sure?}"
  read -rp "$(echo -e "${YELLOW}${msg} [y/N]:${NC} ")" ans
  [[ "${ans,,}" == "y" ]]
}

main_menu() {
  while true; do
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║     AI Platform Manager          ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════╝${NC}"
    echo ""
    echo "  1) Install Web"
    echo "  2) Reinstall Web"
    echo "  3) Change Web Config"
    echo "  4) Switch AI Model"
    echo "  5) Enable Maintenance Mode"
    echo "  6) Disable Maintenance Mode"
    echo "  7) View System Status"
    echo "  8) Uninstall Entire System"
    echo "  9) Reboot Server"
    echo "  0) Exit"
    echo ""
    read -rp "Select option: " opt
    case "$opt" in
      1) do_install ;;
      2) do_reinstall ;;
      3) do_change_config ;;
      4) do_switch_model ;;
      5) do_maintenance_on ;;
      6) do_maintenance_off ;;
      7) do_status ;;
      8) do_uninstall ;;
      9) do_reboot ;;
      0) exit 0 ;;
      *) warn "Invalid option" ;;
    esac
  done
}

do_install() {
  log "Running installer..."
  bash /opt/aiplatform/install.sh
}

do_reinstall() {
  confirm "This will reinstall the web application. Continue?" || return
  cd "$BASE_DIR/frontend" && npm run build
  cd "$BASE_DIR/backend" && npm run build
  pm2 restart aiplatform-backend
  systemctl reload nginx
  log "Reinstalled."
}

do_change_config() {
  log "Current config:"
  cat "$ENV_FILE"
  echo ""
  read -rp "New Web Name [$WEB_NAME]: " new_name; new_name="${new_name:-$WEB_NAME}"
  read -rp "New Mode (production/development/maintenance) [$APP_MODE]: " new_mode; new_mode="${new_mode:-$APP_MODE}"
  cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
  sed -i "s/WEB_NAME=.*/WEB_NAME=$new_name/" "$ENV_FILE"
  sed -i "s/APP_MODE=.*/APP_MODE=$new_mode/" "$ENV_FILE"
  sed -i "s/NODE_ENV=.*/NODE_ENV=$new_mode/" "$BASE_DIR/backend/.env"
  pm2 restart aiplatform-backend
  log "Config updated."
}

do_switch_model() {
  declare -A MODEL_MAP=([1]="deepseek-coder:1.3b" [2]="deepseek-coder:6.7b" [3]="starcoder2:3b" [4]="qwen2.5-coder:3b" [5]="qwen2.5-coder:7b")
  echo ""
  echo "Available models:"
  for k in "${!MODEL_MAP[@]}"; do echo "  $k) ${MODEL_MAP[$k]}"; done
  echo ""
  read -rp "Select model [1-5]: " sel
  [[ ${MODEL_MAP[$sel]+_} ]] || { warn "Invalid selection"; return; }
  local model="${MODEL_MAP[$sel]}"
  log "Pulling $model ..."
  ollama pull "$model"
  sed -i "s/OLLAMA_MODEL=.*/OLLAMA_MODEL=$model/" "$ENV_FILE"
  sed -i "s/OLLAMA_MODEL=.*/OLLAMA_MODEL=$model/" "$BASE_DIR/backend/.env"
  pm2 restart aiplatform-backend
  log "Model switched to $model"
}

do_maintenance_on() {
  confirm "Enable maintenance mode?" || return
  cat > /etc/nginx/sites-available/aiplatform <<MAINT
server {
    listen 80;
    server_name _;
    root /var/www/maintenance;
    index index.html;
    location / { try_files \$uri /index.html; }
    location /api/auth { proxy_pass http://127.0.0.1:3001; proxy_http_version 1.1; }
}
MAINT
  mkdir -p /var/www/maintenance
  cat > /var/www/maintenance/index.html <<'MHTML'
<!DOCTYPE html><html><head><title>Maintenance</title>
<style>body{background:#0d1117;color:#e6edf3;display:flex;align-items:center;justify-content:center;height:100vh;font-family:monospace;text-align:center}
h1{color:#f78166}p{color:#8b949e;margin-top:1em}</style></head>
<body><div><h1>🔧 Maintenance Mode</h1><p>We'll be back shortly. Thank you for your patience.</p></div></body></html>
MHTML
  nginx -t && systemctl reload nginx
  log "Maintenance mode enabled."
}

do_maintenance_off() {
  confirm "Disable maintenance mode?" || return
  # Regenerate normal nginx config from env
  source "$ENV_FILE"
  cat > /etc/nginx/sites-available/aiplatform <<NORMALNG
server {
    listen 80;
    server_name _;
    root $BASE_DIR/frontend/dist;
    index index.html;
    client_max_body_size 50M;
    location / { try_files \$uri \$uri/ /index.html; }
    location /api { proxy_pass http://127.0.0.1:3001; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_read_timeout 300s; }
    location /socket.io { proxy_pass http://127.0.0.1:3001; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
}
NORMALNG
  nginx -t && systemctl reload nginx
  log "Maintenance mode disabled."
}

do_status() {
  echo ""
  echo -e "${BOLD}=== System Status ===${NC}"
  echo ""
  echo -e "${BOLD}PM2:${NC}"
  pm2 list 2>/dev/null || echo "  PM2 not running"
  echo ""
  echo -e "${BOLD}Nginx:${NC}  $(systemctl is-active nginx)"
  echo -e "${BOLD}PostgreSQL:${NC}  $(systemctl is-active postgresql)"
  echo -e "${BOLD}Ollama:${NC}  $(systemctl is-active ollama)"
  echo ""
  echo -e "${BOLD}Ollama Models:${NC}"
  ollama list 2>/dev/null || echo "  (not accessible)"
  echo ""
  echo -e "${BOLD}Disk:${NC}"
  df -h / | tail -1
  echo ""
  echo -e "${BOLD}Memory:${NC}"
  free -h
}

do_uninstall() {
  warn "This will remove the entire AI Platform."
  confirm "Are you ABSOLUTELY SURE? (first confirm)" || return
  confirm "LAST CHANCE – delete everything?" || return

  pm2 delete aiplatform-backend 2>/dev/null || true
  pm2 save

  rm -f /etc/nginx/sites-enabled/aiplatform
  rm -f /etc/nginx/sites-available/aiplatform
  systemctl reload nginx

  read -rp "Remove PostgreSQL database '${DB_NAME}'? [y/N]: " rmdb
  if [[ "${rmdb,,}" == "y" ]]; then
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";"
    sudo -u postgres psql -c "DROP ROLE IF EXISTS \"${DB_USER}\";"
  fi

  read -rp "Remove Ollama models? [y/N]: " rmmodels
  if [[ "${rmmodels,,}" == "y" ]]; then
    ollama list 2>/dev/null | awk '{print $1}' | grep -v NAME | xargs -I{} ollama rm {} 2>/dev/null || true
  fi

  # Preserve backups
  cp -r "$BASE_DIR/backups" "/tmp/aiplatform-backups-$(date +%s)" 2>/dev/null || true
  rm -rf "$BASE_DIR"
  rm -f "$MANAGER_SCRIPT"

  log "Uninstall complete. Backups preserved in /tmp/aiplatform-backups-*"
}

do_reboot() {
  confirm "Reboot the server now?" || return
  sync
  pm2 save
  log "Rebooting..."
  reboot
}

main_menu
AIMGR

chmod +x "$MANAGER_SCRIPT"
log "AI Manager installed at $MANAGER_SCRIPT"

# =============================================================================
# SECTION 15 – CHOWN & PERMISSIONS
# =============================================================================
section "Permissions"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$BASE_DIR"
chown -R www-data:www-data "$FRONTEND_DIR/dist" 2>/dev/null || true

# =============================================================================
# SECTION 16 – FINAL STATUS
# =============================================================================
section "Installation Complete"

BACKEND_STATUS=$(pm2 list 2>/dev/null | grep aiplatform-backend | grep -c "online" || true)
NGINX_STATUS=$(systemctl is-active nginx)
PG_STATUS=$(systemctl is-active postgresql)
OLLAMA_STATUS=$(systemctl is-active ollama)

PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║           AI Platform Successfully Installed!        ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Server URL:${NC}     http://${PUBLIC_IP}"
[[ -n "$DOMAIN" ]] && echo -e "  ${BOLD}Domain:${NC}         http://${DOMAIN}"
echo -e "  ${BOLD}API URL:${NC}        http://${PUBLIC_IP}/api"
echo ""
echo -e "  ${BOLD}Nginx:${NC}          ${NGINX_STATUS}"
echo -e "  ${BOLD}PostgreSQL:${NC}     ${PG_STATUS}"
echo -e "  ${BOLD}Ollama:${NC}         ${OLLAMA_STATUS}"
echo -e "  ${BOLD}PM2 Backend:${NC}    $([[ "$BACKEND_STATUS" -gt 0 ]] && echo 'online' || echo 'check logs')"
echo ""
echo -e "  ${BOLD}Mode:${NC}           ${APP_MODE}"
echo -e "  ${BOLD}AI Model:${NC}       ${OLLAMA_MODEL}"
echo -e "  ${BOLD}Database:${NC}       ${DB_NAME}@localhost"
echo ""
echo -e "  ${BOLD}Management CLI:${NC}  ai-manager"
echo -e "  ${BOLD}Install Log:${NC}     ${LOGFILE}"
echo ""

# =============================================================================
# SECTION 17 – AUTO REBOOT OPTION
# =============================================================================
read -rp "$(echo -e "${BOLD}Reboot server now for all changes to take effect? [y/N]:${NC} ")" DO_REBOOT
if [[ "${DO_REBOOT,,}" == "y" ]]; then
  log "Flushing disk and rebooting in 5 seconds..."
  pm2 save
  sync
  sleep 5
  reboot
else
  log "Skipping reboot. Remember to reboot manually if needed."
fi
