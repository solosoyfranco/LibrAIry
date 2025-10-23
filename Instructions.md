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
wget https://github.com/qarmin/czkawka/releases/download/10.0.0/czkawka_cli_arm64 -O /usr/local/bin/czkawka_cli


  
## run:
chmod +x /workspace/inbox-processor/scripts/step1.sh
/workspace/inbox-processor/scripts/step1.sh 

# step2