#!/usr/bin/env bash
set -e

echo "======================================="
echo "MacOS Dev Environment Bootstrap"
echo "======================================="

########################################
# install homebrew
########################################

if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# load brew env
if [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

brew update

########################################
# install base packages
########################################

echo "Installing base tools..."

brew install \
git \
curl \
wget \
zsh \
tmux \
htop \
jq \
ripgrep \
fd \
tree \
ncdu

########################################
# set zsh as default shell
########################################

ZSH_PATH="$(command -v zsh)"

if ! grep -qx "$ZSH_PATH" /etc/shells; then
  echo "Adding $ZSH_PATH to /etc/shells..."
  echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
fi

if [[ "$SHELL" != "$ZSH_PATH" ]]; then
  echo "Setting default shell to $ZSH_PATH..."
  chsh -s "$ZSH_PATH"
fi

########################################
# install oh-my-zsh
########################################

if [ ! -d "$HOME/.oh-my-zsh" ]; then
  echo "Installing Oh My Zsh..."
  RUNZSH=no sh -c \
  "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

########################################
# install nvm
########################################

if [ ! -d "$HOME/.nvm" ]; then
  echo "Installing NVM..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

echo "Installing Node LTS..."
nvm install --lts
nvm use --lts

########################################
# install pyenv
########################################

brew install pyenv

if ! grep -q 'pyenv init' ~/.zshrc; then
cat <<EOF >> ~/.zshrc

# pyenv
export PYENV_ROOT="\$HOME/.pyenv"
export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"

EOF
fi

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"

eval "$(pyenv init -)"

########################################
# install latest python
########################################

echo "Installing latest Python..."

LATEST_PY=$(pyenv install --list | grep -E "^\s*3\.[0-9]+\.[0-9]+$" | tail -1 | xargs)

pyenv install -s $LATEST_PY
pyenv global $LATEST_PY

python -m pip install --upgrade pip setuptools wheel

########################################
# install useful global tools
########################################

brew install \
fzf \
bat \
eza

########################################

echo
echo "======================================="
echo "Setup Complete"
echo "======================================="

echo "Node version:"
node -v

echo "Python version:"
python -V

echo "Restart terminal to apply environment."
