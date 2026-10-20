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

# ── 3 bis. PyTorch cu130 : OBLIGATOIRE pour que VSA fonctionne ──────────────
# ⛔ Paye le 2026-10-20. L'image runpod/pytorch:...-cu1290 livre torch+cu128, et
# ComfyUI desactive alors son backend CUDA (comfy/quant_ops.py) :
#     if cuda_version < (13,): ck.registry.disable("cuda")
# Consequence : le nodule Ref2VA-VSA leve BackendNotFoundError a la premiere
# passe d'attention, et la generation echoue en moins d'une seconde. Le symptome
# est trompeur — on croit a un probleme de VRAM ou de poids.
# Meme version de torch (2.9.0), seul le suffixe CUDA change : changement minimal.
# Ce paquet vit dans le DISQUE CONTENEUR, pas dans /workspace : il est donc a
# refaire sur un pod neuf, d'ou sa place ici.
TORCH_CUDA=$(python3 -c 'import torch; print(torch.version.cuda or "0")')
TORCH_MAJ=${TORCH_CUDA%%.*}
if [ "${TORCH_MAJ:-0}" -lt 13 ]; then
  date -u +"[%Y-%m-%dT%H:%M:%SZ] torch+cu$TORCH_CUDA < cu130 : installation de cu130"
  TORCH_V=$(python3 -c 'import torch; print(torch.__version__.split("+")[0])')
  if python3 -m pip install --quiet --no-cache-dir \
       --index-url https://download.pytorch.org/whl/cu130 \
       "torch==${TORCH_V}+cu130" 2>/dev/null; then
    date -u +"[%Y-%m-%dT%H:%M:%SZ] torch ${TORCH_V}+cu130 installe"
  else
    date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC de l'installation de torch cu130 : VSA ne marchera pas"
  fi
  # torchvision doit suivre la meme version de CUDA, sinon il casse a l'import.
  #
  # ⛔ Paye le 2026-10-20, et le piege est retors : cette correction EXISTAIT,
  # mais sa sonde de version faisait `import torchvision`. Or torch vient de
  # passer en cu130 alors que torchvision est encore en cu128 : l'import leve
  #     RuntimeError: PyTorch has CUDA Version=13.0 and torchvision has CUDA
  #     Version=12.8. Please reinstall the torchvision that matches...
  # donc TV_V restait vide, la correction etait sautee EN SILENCE (2>/dev/null),
  # et ComfyUI mourait plus loin sur `from torchvision import transforms`.
  # ➜ On lit la version par les METADONNEES, qui n'importent rien.
  TV_V=$(python3 -c 'from importlib.metadata import version; print(version("torchvision").split("+")[0])' 2>/dev/null || true)
  if [ -n "${TV_V:-}" ]; then
    if python3 -m pip install --quiet --no-cache-dir \
         --index-url https://download.pytorch.org/whl/cu130 \
         "torchvision==${TV_V}+cu130"; then
      date -u +"[%Y-%m-%dT%H:%M:%SZ] torchvision ${TV_V}+cu130 installe"
    else
      date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC de l'installation de torchvision ${TV_V}+cu130"
    fi
  else
    date -u +"[%Y-%m-%dT%H:%M:%SZ] ATTENTION torchvision absent des metadonnees"
  fi
  # Relecture : un pip qui rend 0 ne prouve pas que l'import fonctionne.
  if python3 -c 'import torch, torchvision; from torchvision import transforms; assert "cu" + torch.version.cuda.replace(".", "") == torchvision.__version__.split("+")[-1], (torch.version.cuda, torchvision.__version__)'; then
    date -u +"[%Y-%m-%dT%H:%M:%SZ] torchvision importable ($(python3 -c 'import torchvision; print(torchvision.__version__)'))"
  else
    date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC torchvision reste incompatible avec torch : ComfyUI ne demarrera pas"
  fi

  # ── 3 ter. torchaudio : le TROISIEME paquet du trio ──────────────────────
  # ⛔ Paye le 2026-10-20, apres torchvision. Meme cause, meme silence : torch
  # passe en cu130, torchaudio reste en cu128. ComfyUI demarre quand meme, donc
  # rien ne crie — mais le pack Motion Context importe torchaudio dans nodes.py
  # et ComfyUI journalise seulement :
  #     Cannot import .../ComfyUI-H3-Motion-Context : PyTorch has CUDA 13.0
  #     whereas TorchAudio has CUDA 12.8
  #     Import times for custom nodes: 0.0 seconds (IMPORT FAILED)
  # Le noeud n'existe pas, et on cherche le bug dans le workflow.
  # ⛔ Corriger torch seul, ou torch+torchvision, ne suffit pas : les trois
  # doivent partager le meme CUDA majeur.
  TA_V=$(python3 -c 'from importlib.metadata import version; print(version("torchaudio").split("+")[0])' 2>/dev/null || true)
  if [ -n "${TA_V:-}" ]; then
    if python3 -m pip install --quiet --no-cache-dir \
         --index-url https://download.pytorch.org/whl/cu130 \
         "torchaudio==${TA_V}+cu130" --force-reinstall --no-deps; then
      date -u +"[%Y-%m-%dT%H:%M:%SZ] torchaudio ${TA_V}+cu130 installe"
    else
      date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC de l'installation de torchaudio ${TA_V}+cu130"
    fi
  else
    date -u +"[%Y-%m-%dT%H:%M:%SZ] torchaudio absent : rien a aligner"
  fi
  if python3 -c 'import torch, torchaudio; assert "cu" + torch.version.cuda.replace(".", "") == torchaudio.__version__.split("+")[-1], (torch.version.cuda, torchaudio.__version__)'; then
    date -u +"[%Y-%m-%dT%H:%M:%SZ] torchaudio importable ($(python3 -c 'import torchaudio; print(torchaudio.__version__)'))"
  else
    date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC torchaudio reste incompatible : Motion Context ne chargera pas"
  fi
else
  date -u +"[%Y-%m-%dT%H:%M:%SZ] torch deja en cu$TORCH_CUDA (>= 13) : rien a faire"
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

# ── 4 bis. RETIRE le 2026-10-20 : le decodeur 2X du VAE X2-Detail ───────────
# Le depot ComfyUI-MiniMaxH3_LatentUpscaler et le VAE X2 (5,25 Go) ont ete
# retires. Raison : leur auteur qualifie ce depot de « A Failed HQ-VAE
# Experiment » — le mode detail exige des features de l'image RGB d'origine,
# absentes sur un latent genere, et le mode 2X double les pixels sans ajouter
# d'information. 5,25 Go et un noeud pour aucun gain de detail.
#
# Pour le remettre : cloner le depot ci-dessous, decommenter le poids dans
# poids-a-telecharger.txt, ET utiliser le noeud `MiniMax H3 VAE Decode (fast)`
# (le VAEDecode normal ne double rien). Reglages valides par l'auteur :
#   tiling=true, tile_size=256, tile_overlap=64, output_device=cpu,
#   temporal_tiling=false   (le tuilage n'est pas optionnel en 24 Go)
# git clone --depth 1 https://github.com/TripleHeadedMonkey/ComfyUI-MiniMaxH3_LatentUpscaler.git \
#   "$WS/ComfyUI/custom_nodes/ComfyUI-MiniMaxH3_LatentUpscaler"

# ── 4 ter. H3 Motion Context : le chainage latent qui supprime les coutures ──
# Verifie le 2026-10-20 : le depot existe, v0.7.1, 1,3k etoiles, GPL-3.0.
#
# Pourquoi ce pack et pas une re-injection d'image : ref2va seul repart d'une
# IMAGE ; le raccord passe donc par des pixels (decodage, redimensionnement,
# re-encodage), et c'est exactement la ou naissent la derive de couleur et le
# ramollissement le long d'une chaine. Motion Context preleve les dernieres
# frames DIRECTEMENT DANS LE LATENT du clip precedent : les frames epinglees
# sont les memes nombres, bit pour bit, et l'audio est prolonge au lieu d'etre
# rejoue.
#
# ⛔ NE PAS installer aussi le fork seitanism/ComfyUI-H3-Motion-Context-MultiRef.
# Le README est explicite : « Only install this once. A fork of this repo (...)
# will all load. » Deux copies = deux enregistrements des memes noeuds, et
# rien ne dit laquelle repond. Le fork ajoute AV Extension / Music Video / V2V,
# dont nous n'avons pas besoin ici, et reclame VHS + KJNodes + SolAttn + MAINodes
# en plus : quatre packs de plus a faire echouer.
#
# ⛔ Version : exige ComfyUI >= 0.34.0 (les ancres de keyframe arbitraires).
# L'image installe 0.42.0, donc v0.7.1 convient. Sur une image plus ancienne, le
# pack REFUSE de tourner et le dit — un echec bruyant, pas un mauvais rendu.
MC="$WS/ComfyUI/custom_nodes/ComfyUI-H3-Motion-Context"
if [ ! -d "$MC/.git" ]; then
  rm -rf "$MC"
  git clone --depth 1 --branch v0.7.1 \
    https://github.com/NikoDemon80/ComfyUI-H3-Motion-Context.git "$MC" \
    || git clone --depth 1 \
         https://github.com/NikoDemon80/ComfyUI-H3-Motion-Context.git "$MC"
fi
if [ -d "$MC" ]; then
  date -u +"[%Y-%m-%dT%H:%M:%SZ] nodule Motion Context present : $(git -C "$MC" rev-parse --short HEAD 2>/dev/null || echo 'sans git')"
  for req in requirements.txt pyproject.toml; do
    if [ -f "$MC/$req" ] && [ "$req" = "requirements.txt" ]; then
      python3 -m pip install --quiet -r "$MC/$req" \
        && date -u +"[%Y-%m-%dT%H:%M:%SZ] dependances Motion Context installees"
    fi
  done
  # Le pack s'auto-verifie contre le code de ComfyUI au premier rendu. On note
  # la version pour pouvoir dater un refus.eventuel.
  date -u +"[%Y-%m-%dT%H:%M:%SZ] Motion Context pret (auto-controle au 1er rendu)"
else
  date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC du clone Motion Context : pas de chainage latent"
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
#
# ⛔ CORRIGE le 2026-10-20 : ce script LISAIT $WS/poids-a-telecharger.txt sans
# jamais le telecharger. Sur un pod neuf, le fichier n'existe pas, donc l'etape
# poids etait silencieusement sautee et l'installation se disait « terminee »
# avec zero modele. Le manifeste est maintenant recupere depuis le bootstrap
# public, avec une verification qu'il n'est pas vide.
MANIFESTE="$WS/poids-a-telecharger.txt"
URL_MANIFESTE="${MANIFESTE_URL:-https://raw.githubusercontent.com/Gamma-Burst/h3-bootstrap/main/poids-a-telecharger.txt}"
if [ ! -s "$MANIFESTE" ]; then
  date -u +"[%Y-%m-%dT%H:%M:%SZ] telechargement du manifeste des poids"
  curl -fsSL --retry 3 --max-time 120 "$URL_MANIFESTE" -o "$MANIFESTE" \
    || date -u +"[%Y-%m-%dT%H:%M:%SZ] ECHEC du telechargement du manifeste"
fi
if [ -s "$MANIFESTE" ]; then
  date -u +"[%Y-%m-%dT%H:%M:%SZ] manifeste present : $(wc -l < "$MANIFESTE") lignes"
  while IFS='|' read -r nom url dep attendu; do
    [ -z "${nom:-}" ] && continue
    case "$nom" in \#*) continue ;; esac
    telecharger "$url" "$WS/models/$dep/$nom" "${attendu:-0}"
  done < "$MANIFESTE"
else
  date -u +"[%Y-%m-%dT%H:%M:%SZ] PAS DE MANIFESTE : aucun poids telecharge"
fi

# ── 6. Etat final, mesurable ────────────────────────────────────────────────
echo "--- poids presents ---"
find "$WS/models" -type f \( -name '*.safetensors' -o -name '*.gguf' \) \
  -printf '%10s  %p\n' | sort -rn
echo "--- espace disque ---"
df -h "$WS" | tail -1
du -sh "$WS"/* 2>/dev/null | sort -h | tail -10

# ⛔ Un script qui annonce « termine » avec zero modele est pire qu'un script qui
# plante : il laisse croire que tout va bien. On compte les poids et on refuse
# de pretendre que l'installation a reussi s'il n'y en a pas au moins 5.
NB_POIDS=$(find "$WS/models" -type f -name '*.safetensors' 2>/dev/null | wc -l)
OCTETS_POIDS=$(du -sb "$WS/models" 2>/dev/null | cut -f1)
OCTETS_POIDS=${OCTETS_POIDS:-0}
# Le nombre attendu vient du MANIFESTE, pas d'une constante ecrite ici : ajouter
# un poids au manifeste ne doit pas casser le controle.
NB_ATTENDU=$(grep -vc '^\s*\(#\|$\)' "$MANIFESTE" 2>/dev/null || echo 6)
NB_ATTENDU=${NB_ATTENDU:-6}
date -u +"[%Y-%m-%dT%H:%M:%SZ] $NB_POIDS fichier(s) de poids, $OCTETS_POIDS octets (attendu : $NB_ATTENDU)"
if [ "$NB_POIDS" -lt "$NB_ATTENDU" ]; then
  INSTALLATION_OK=0
  date -u +"[%Y-%m-%dT%H:%M:%SZ] INSTALLATION INCOMPLETE : $NB_POIDS poids au lieu de $NB_ATTENDU"
else
  INSTALLATION_OK=1
  date -u +"[%Y-%m-%dT%H:%M:%SZ] installation des poids complete"
fi

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
  "poids_fichiers": $NB_POIDS,
  "poids_octets": $OCTETS_POIDS,
  "installation_ok": $INSTALLATION_OK,
  "test_comfyui_code": $CODE,
  "log": "$LOG"
}
JSON
cat "$ETAT"
date -u +"[%Y-%m-%dT%H:%M:%SZ] FIN DE L'INSTALLATION (ok=$INSTALLATION_OK)"

# ── 7. Delai de grace : laisser le temps de LIRE et d'INSPECTER ─────────────
# Paye deux fois le 2026-10-20 : le script s'arretait dans la seconde qui suivait
# la fin, donc le pod devenait inaccessible et je n'ai jamais pu lire etat.json.
#
# ⛔ ET NE PAS FAIRE `kill` SUR LE VEILLEUR : tuer le `sleep` fait CONTINUER le
# sous-shell, qui appelle podStop immediatement. C'est arrive, et ca a coupe le
# pod une minute apres la fin au lieu de vingt. On pilote donc par un DRAPEAU :
#   touch /workspace/NE-PAS-ARRETER   -> le pod reste allume, indefiniment
#   rm    /workspace/NE-PAS-ARRETER   -> il s'arrete (au plus tard 30 s apres)
GRACE_MIN=${GRACE_MIN:-20}
if [ "$GRACE_MIN" -gt 0 ]; then
  echo "installation_terminee:$INSTALLATION_OK" > "$WS/arret-raison.txt"
  date -u +"[%Y-%m-%dT%H:%M:%SZ] delai de grace ${GRACE_MIN} min (drapeau : $WS/NE-PAS-ARRETER)"
  (
    fin=$(( $(date +%s) + GRACE_MIN * 60 ))
    while [ "$(date +%s)" -lt "$fin" ]; do sleep 15; done
    while [ -f "$WS/NE-PAS-ARRETER" ]; do sleep 30; done
    date -u +"[%Y-%m-%dT%H:%M:%SZ] fin du delai de grace : arret"
    curl -s -X POST "https://api.runpod.io/graphql" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${RUNPOD_API_KEY:-}" \
      -d "{\"query\":\"mutation { podStop(input: {podId: \\\"${RUNPOD_POD_ID:-}\\\"}) { id } }\"}" \
      >> "$LOG" 2>&1
  ) &
  wait $!
  exit 0
fi

# ── 7 bis. Arret : le pod ne doit pas rester a tourner sans surveillance ────
kill "$VEILLEUR" 2>/dev/null
echo "installation_terminee:$INSTALLATION_OK" > "$WS/arret-raison.txt"
date -u +"[%Y-%m-%dT%H:%M:%SZ] arret du pod"
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${RUNPOD_API_KEY:-}" \
  -d "{\"query\":\"mutation { podStop(input: {podId: \\\"${RUNPOD_POD_ID:-}\\\"}) { id } }\"}"
date -u +"[%Y-%m-%dT%H:%M:%SZ] STOP envoye"
