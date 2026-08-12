#!/usr/bin/env bash
#
# Run this ON YOUR MAC (not in the container) after the container is up, once
# per rebuild. It copies your PUBLIC ssh key into the container so Claude Code
# Desktop can open an SSH session there.
#
# Why a script instead of a bind mount: the devcontainer docs are explicit about
# not mounting ~/.ssh into a container, and a bind mount of a single file that
# does not exist on the host silently becomes a directory. Pushing the one
# public key in over docker exec avoids both. Public keys are not secrets; your
# private key never enters the container.
#
#   ./.devcontainer/authorize-ssh-key.sh [path/to/key.pub]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KEY="${1:-}"
if [ -z "$KEY" ]; then
  for candidate in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    [ -f "$candidate" ] && { KEY="$candidate"; break; }
  done
fi
if [ -z "$KEY" ] || [ ! -f "$KEY" ]; then
  echo "No public key found. Generate one with:" >&2
  echo "  ssh-keygen -t ed25519" >&2
  echo "or pass the path: $0 ~/.ssh/some_key.pub" >&2
  exit 1
fi

# Both the devcontainer CLI and VS Code label the container with the workspace
# path they opened, which is how we find it without knowing its generated name.
CID="$(docker ps -q --filter "label=devcontainer.local_folder=$REPO" | head -1)"
if [ -z "$CID" ]; then
  echo "No running devcontainer for $REPO." >&2
  echo "Start it first:  devcontainer up --workspace-folder ." >&2
  exit 1
fi

docker exec -u vscode -i "$CID" sh -c \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && \
   sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && \
   chmod 600 ~/.ssh/authorized_keys' < "$KEY"

echo "Authorized $(basename "$KEY") in container ${CID:0:12}."
echo
echo "Now add the connection in Claude Code Desktop:"
echo "  environment dropdown -> + Add SSH connection"
echo "    SSH Host:      vscode@localhost"
echo "    SSH Port:      2222"
echo "    Identity File: ${KEY%.pub}"
echo
echo "Check it first if you like:  ssh -p 2222 -i ${KEY%.pub} vscode@localhost"
