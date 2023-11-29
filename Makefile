SHELL=/bin/bash
registry_port=5000
git_remote=$(shell git remote | head -1)

all:

start_registry:
	 docker run \
 		--rm \
 		--detach \
 		--publish $(registry_port):5000 \
 		--name registry registry:2.7

check_registry:
	@curl --fail http://localhost:$(registry_port)/ \
		|| { echo "Run 'make start_registry' first" ; false ; }

images: check_registry
	DOCKER_HOST=$$(docker context inspect --format '{{.Endpoints.docker.Host}}') \
	act \
		--var DOCKERHUB_REPOSITORY="localhost:$(registry_port)/docker.io/ucscgi/azul-pycharm" \
		--remote-name $(git_remote) \
		push

stop_registry:
	 docker stop registry
