docker run -it \
  --name devbox \
  -v "$PWD":/workspace \
  -v "$HOME/Desktop/inbox-test":/data \
  debian:bookworm-slim bash

  


If you’re installing lots of packages and don’t want to redo them every time:
docker commit devbox my/devbox:latest


Then later you can just run:
docker start -ai devbox



### install:
  apt update
apt install -y rmlint jq coreutils
# step2
apt update && apt install -y jq wget
apt install ffmpeg
wget https://github.com/qarmin/czkawka/releases/download/10.0.0/linux_czkawka_cli_arm64 -O /usr/local/bin/czkawka_cli
chmod +x /usr/local/bin/czkawka_cli
czkawka_cli --version

apt update && apt install -y \
  jq wget curl git \
  build-essential pkg-config cmake nasm yasm clang g++ gcc \
  libjpeg-dev libpng-dev libtiff-dev libtag1-dev \
  libaom-dev libdav1d-dev libavif-dev libheif-dev libx264-dev libx265-dev \
  ffmpeg
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
rustc --version
cargo --version

git clone https://github.com/qarmin/czkawka.git /opt/czkawka
cd /opt/czkawka
export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig

cargo build --release --bin czkawka_cli -p czkawka_cli --features "czkawka_core/heif czkawka_core/libavif"

<!-- cargo build --release --bin czkawka_cli -p czkawka_cli \
  --features "czkawka_core/heif czkawka_core/libavif"
apt install -y pkg-config libdav1d-dev libaom-dev libavif-dev libheif-dev -->
cp target/release/czkawka_cli /usr/local/bin/
chmod +x /usr/local/bin/czkawka_cli

######## is working but step2summary is empty
  
## run:
chmod +x /workspace/inbox-processor/scripts/step1.sh
/workspace/inbox-processor/scripts/step1.sh 

# step2
