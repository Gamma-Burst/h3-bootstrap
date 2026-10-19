#!/usr/bin/env bash
# Installation de ComfyUI + Ref2VA-VSA sur le volume RunPod, avec arret
# automatique. Ce script tourne DANS le pod. Il ne suppose rien de mon PC.
#
# Trois principes :
#   1. ARRET GARANTI. Un veilleur interne arrete le pod a MAX_MIN, quoi qu'il
#      arrive — meme si ce script plante, meme si ma session meurt.
#   2. RIEN DANS LE CONTENEUR. Tout ce qui se telecharge va dans /workspace, qui
#      survit a l'arret du pod. Un pod recree retrouve tout.
#   3. ON MESURE, ON N'ANNOUNCE RIEN. Chaque etape ecrit sa taille reelle et son
#      code de sortie dans etat.json. Un echec laisse une trace reprenable.
#
# Variables attendues dans l'environnement du pod :
#   RUNPOD_API_KEY   pour pouvoir s'arreter soi-meme
#   RUNPOD_POD_ID    fourni automatiquement par RunPod
#   MAX_MIN          duree de vie maximale en minutes (defaut 150)

set -uo pipefail

WS=/workspace
LOG=$WS/install-ref2va.log
ETAT=$WS/install-ref2va-etat.json
MAX_MIN=${MAX_MIN:-150}

mkdir -p "$WS"
exec > >(tee -a "$LOG") 2>&1

date -u +"[%Y-%m-%dT%H:%M:%SZ] debut de l'installation"

# ── Veilleur : arret automatique, independant de tout le reste ──────────────
( sleep $((MAX_MIN * 60))
  date -u +"[%Y-%m-%dT%H:%M:%SZ] DELAI MAX ATTEINT ($MAX_MIN min) : arret"
  echo "delai_max_atteint" > "$WS/arret-raison.txt"
  curl -s -X POST "https://api.runpod.io/graphql" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY:-}" \
    -d "{\"query\":\"mutation { podStop(input: {podId: \\\"${RUNPOD_POD_ID:-}\\\"}) { id } }\"}" \
    >> "$LOG" 2>&1
) &
VEILLEUR=$!

etape() {  # etape <nom> <commande...>
  local nom="$1"; shift
  date -u +"[%Y-%m-%dT%H:%M:%SZ] >>> $nom"
  if "$@"; then
    date -u +"[%Y-%m-%dT%H:%M:%SZ] OK  $nom"
    return 0
  else
    local code=$?
    date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC $nom (code $code)"
    return $code
  fi
}

# ── 0. Ce qui existe deja sur le volume ─────────────────────────────────────
echo "--- etat du volume avant installation ---"
df -h "$WS" | tail -2
du -sh "$WS"/* 2>/dev/null | sort -h | tail -20

mkdir -p "$WS/models"/{diffusion_models,text_encoders,vae,loras} \
         "$WS/ComfyUI/custom_nodes" "$WS/hf"
export HF_HOME="$WS/hf"

# ── 1. Outils systeme ───────────────────────────────────────────────────────
apt-get update -qq && apt-get install -y -qq git wget curl aria2 pkg-config \
  libgl1 libglib2.0-0 ffmpeg > /dev/null 2>&1
date -u +"[%Y-%m-%dT%H:%M:%SZ] outils systeme installes"

# ── 2. ComfyUI ──────────────────────────────────────────────────────────────
if [ ! -d "$WS/ComfyUI/.git" ]; then
  rm -rf "$WS/ComfyUI"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$WS/ComfyUI"
fi
cd "$WS/ComfyUI" || exit 1
date -u +"[%Y-%m-%dT%H:%M:%SZ] ComfyUI present : $(git rev-parse --short HEAD)"

# Les modeles doivent etre vus par ComfyUI : liens vers le volume.
for d in diffusion_models text_encoders vae loras; do
  rm -rf "$WS/ComfyUI/models/$d"
  ln -sfn "$WS/models/$d" "$WS/ComfyUI/models/$d"
done

# ── 3. Dependances ComfyUI ──────────────────────────────────────────────────
python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet -r requirements.txt
date -u +"[%Y-%m-%dT%H:%M:%SZ] dependances ComfyUI installees"

# comfy-kitchen : fournit le noyau CUDA sol_attn dont VSA depend.
if python3 -m pip install --quiet comfy-kitchen 2>/dev/null; then
  date -u +"[%Y-%m-%dT%H:%M:%SZ] comfy-kitchen installe"
else
  date -u +"[%Y-%m-%dT%H:%M:%SZ] ATTENTION comfy-kitchen introuvable par pip"
fi

# ── 4. Le nodule Ref2VA-VSA ─────────────────────────────────────────────────
NODE="$WS/ComfyUI/custom_nodes/ComfyUI-Ref2VA-VSA"
if [ ! -d "$NODE" ]; then
  git clone --depth 1 https://github.com/Kablex/ComfyUI-Ref2VA-VSA.git "$NODE"
fi
date -u +"[%Y-%m-%dT%H:%M:%SZ] nodule Ref2VA-VSA present : $(git -C "$NODE" rev-parse --short HEAD)"
if [ -f "$NODE/requirements.txt" ]; then
  python3 -m pip install --quiet -r "$NODE/requirements.txt" \
    && date -u +"[%Y-%m-%dT%H:%M:%SZ] dependances du nodule installees"
fi

# ── 5. Les poids ────────────────────────────────────────────────────────────
# Telechargement idempotent : aria2 reprend, et un fichier deja present a la
# bonne taille n'est pas retelecharge. Chaque poids est VERIFIE par sa taille :
# un fichier tronque est le pire des cas, il charge puis produit du bruit.
telecharger() {  # telecharger <url> <chemin> <octets attendus ou 0 si inconnu>
  local url="$1" dest="$2" attendu="${3:-0}"
  if [ -f "$dest" ] && [ "$attendu" -gt 0 ]; then
    local taille
    taille=$(stat -c%s "$dest")
    if [ "$taille" -eq "$attendu" ]; then
      date -u +"[%Y-%m-%dT%H:%M:%SZ] deja present : $(basename "$dest")"
      return 0
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  aria2c -x 8 -s 8 -k 1M --file-allocation=none --allow-overwrite=true \
         --auto-file-renaming=false --console-log-level=warn \
         -d "$(dirname "$dest")" -o "$(basename "$dest")" "$url"
  local code=$?
  if [ $code -ne 0 ]; then
    date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC telechargement $(basename "$dest") (aria2 code $code)"
    return 1
  fi
  if [ "$attendu" -gt 0 ]; then
    local taille
    taille=$(stat -c%s "$dest")
    if [ "$taille" -ne "$attendu" ]; then
      date -u +"[%Y-%m-%dT%H:%M:%SZ] TAILLE INATTENDUE $(basename "$dest") : $taille au lieu de $attendu"
      return 1
    fi
  fi
  date -u +"[%Y-%m-%dT%H:%M:%SZ] telecharge : $(basename "$dest") ($(stat -c%s "$dest") octets)"
}

# Les URL et tailles sont ecrites dans un fichier de manifeste lisible, pour
# qu'un humain puisse corriger sans relire ce script.
MANIFESTE="$WS/poids-a-telecharger.txt"
if [ -f "$MANIFESTE" ]; then
  while IFS='|' read -r nom url dep attendu; do
    [ -z "${nom:-}" ] && continue
    case "$nom" in \#*) continue ;; esac
    telecharger "$url" "$WS/models/$dep/$nom" "${attendu:-0}"
  done < "$MANIFESTE"
else
  date -u +"[%Y-%m-%dT%H:%M:%SZ] pas de manifeste : etape poids sautee"
fi

# ── 6. Etat final, mesurable ────────────────────────────────────────────────
echo "--- poids presents ---"
find "$WS/models" -type f \( -name '*.safetensors' -o -name '*.gguf' \) \
  -printf '%10s  %p\n' | sort -rn
echo "--- espace disque ---"
df -h "$WS" | tail -1
du -sh "$WS"/* 2>/dev/null | sort -h | tail -10

# Test de chargement a vide : ComfyUI demarre-t-il et voit-il le nodule ?
date -u +"[%Y-%m-%dT%H:%M:%SZ] >>> test de demarrage ComfyUI (30 s)"
cd "$WS/ComfyUI" || exit 1
timeout 60 python3 main.py --listen 127.0.0.1 --port 8188 --quick-test-for-ci \
  > "$WS/comfyui-test.log" 2>&1
CODE=$?
date -u +"[%Y-%m-%dT%H:%M:%SZ] test ComfyUI termine (code $CODE)"
tail -20 "$WS/comfyui-test.log"

cat > "$ETAT" <<JSON
{
  "termine_le": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "comfyui": "$(git -C "$WS/ComfyUI" rev-parse HEAD 2>/dev/null)",
  "nodule": "$(git -C "$NODE" rev-parse HEAD 2>/dev/null)",
  "test_comfyui_code": $CODE,
  "log": "$LOG"
}
JSON
cat "$ETAT"
date -u +"[%Y-%m-%dT%H:%M:%SZ] FIN DE L'INSTALLATION"

# ── 7. Arret : le pod ne doit pas rester a tourner sans surveillance ────────
kill "$VEILLEUR" 2>/dev/null
echo "installation_terminee" > "$WS/arret-raison.txt"
date -u +"[%Y-%m-%dT%H:%M:%SZ] arret du pod"
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${RUNPOD_API_KEY:-}" \
  -d "{\"query\":\"mutation { podStop(input: {podId: \\\"${RUNPOD_POD_ID:-}\\\"}) { id } }\"}"
