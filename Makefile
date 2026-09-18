SHELL=/bin/bash
registry_port=5000
git_remote=$(shell git remote | head -1)

#	The workflow is the single source of truth for the version of PyCharm
#
workflow=.github/workflows/docker-publish.yml
pycharm_version=$(shell sed -n 's/^ *azul_docker_pycharm_upstream_version: //p' $(workflow))

all:

#	Refresh the checksums of the PyCharm archives after changing the version of
#	PyCharm in the workflow. JetBrains publishes one checksum file per archive,
#	so we concatenate the two we care about into the format `sha256sum -c`
#	expects.
#
pycharm_checksums:
	rm -f pycharm_checksums.txt
	for arch in "" -aarch64 ; do \
	    curl --fail --silent --location \
	        https://download.jetbrains.com/python/pycharm-$(pycharm_version)$$arch.tar.gz.sha256 \
	        >> pycharm_checksums.txt ; \
	done

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
		--env azul_docker_registry="localhost:$(registry_port)/" \
		--remote-name $(git_remote) \
		push

stop_registry:
	 docker stop registry
