#!/bin/bash

docker run -it -v $(pwd):/data -w /data --network host jekyll $@
