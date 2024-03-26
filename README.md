Docker container to run PyCharm Community Edition (https://www.jetbrains.com/pycharm/)

### Usage

```
docker run --rm \
  -e DISPLAY=${DISPLAY} \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v ~/.PyCharm:/home/developer/.PyCharm \
  -v ~/.PyCharm.java:/home/developer/.java \
  -v ~/.PyCharm.py3:/usr/local/lib/python3.7 \
  -v ~/.PyCharm.share:/home/developer/.local/share/JetBrains \
  -v ~/Project:/home/developer/Project \
  --name pycharm-$(head -c 4 /dev/urandom | xxd -p)-$(date +'%Y%m%d-%H%M%S') \
rycus86/pycharm:latest
```

Docker Hub Page: https://hub.docker.com/r/rycus86/pycharm/

### Notes

The IDE will have access to Python 3 and to Git.
Project folders need to be mounted like `-v ~/Project:/home/developer/Project`.
The actual name can be anything - I used something random to be able to start multiple instances if needed.

To use `pip`, either use the terminal in PyCharm or install from the terminal from inside the container like `docker exec -it pycharm-running bash` then install using **pip**.

### Azul Notes

Changes can be tested locally. You would need `make`, `curl`, Docker Desktop and 
[act](https://github.com/nektos/act). For example:

```
brew install act
act # the first invocation is to interactively configure `act`
make start_registry
make images
# scroll up in terminal output, note image name
# |   "image.name": "localhost:5000/docker.io/ucscgi/azul-pycharm:2023.2.3-5"
docker pull localhost:5000/docker.io/ucscgi/azul-pycharm:2023.2.3-5
# To examine the image for vulnerabilities, browse the image in Docker Desktop.
# If an unnecessary package is found to have critical or high vulnerabilities,
# To test the image in Azul, you will need to temporarily modify Azul's
# `environment.py` to set the appropriate `azul_docker_images` value using the
# full image name noted above (starting with "localhost").
cd ../azul
git diff
>   diff --git a/environment.py b/environment.py
>   index f888a1b8e..e41273695 100644
>   --- a/environment.py
>   +++ b/environment.py
>   @@ -273,7 +273,7 @@ def env() -> Mapping[str, Optional[str]]:
>                    'ref': 'docker.io/library/python:{azul_python_version}-bullseye'
>                },
>                'pycharm': {
>   -                'ref': 'docker.io/ucscgi/azul-pycharm:2023.3.4-15'
>   +                'ref': 'localhost:5000/docker.io/ucscgi/azul-pycharm:2023.3.4-15'
>                },
>                'elasticsearch': {
>                    'ref': 'docker.io/ucscgi/azul-elasticsearch:7.17.18-13'
make image_manifests.json
azul_docker_registry="" make format
cd -
make stop_registry
```
