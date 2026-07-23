FROM public.ecr.aws/docker/library/alpine@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d

COPY marker /ci-native-image-marker
CMD ["/bin/sh","-c","test \"$(cat /ci-native-image-marker)\" = immutable-native-image && printf 'native-image-archive-ok\\n'"]
