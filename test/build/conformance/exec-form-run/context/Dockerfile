FROM base AS parent
ARG BUILD_ARG=default-arg
ENV INHERITED_ENV=parent-env
ENV ORDER=env-before-arg
ARG ORDER=arg-after-env
RUN mkdir -p /oracle/path-a /oracle/path-b && printf '#!/bin/sh\nprintf wrong > /oracle/path-result\n' > /oracle/path-a/tool && printf '#!/bin/sh\nprintf right > /oracle/path-result\n' > /oracle/path-b/tool && chmod 0644 /oracle/path-a/tool && chmod 0755 /oracle/path-b/tool
ENV PATH=/oracle/path-a:/oracle/path-b:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN ["tool"]
RUN ["python3","-c","import json,os,pathlib,sys; pathlib.Path('/oracle/parent.json').write_text(json.dumps({'argv':sys.argv[1:],'env':[os.getenv('INHERITED_ENV'),os.getenv('BUILD_ARG'),os.getenv('ORDER'),str('UNSET' in os.environ)]},sort_keys=True))","two words","","\"quoted\"","$UNSET"]

FROM parent
ARG BUILD_ARG
ARG ORDER
ENV ORDER=env-after-arg
RUN ["sh","-c","test \"$INHERITED_ENV\" = parent-env && test \"$BUILD_ARG\" = cli-arg && test \"$ORDER\" = env-after-arg && test -z \"${UNSET+x}\" && printf inherited > /oracle/inherited"]
RUN ["python3","-c","import pathlib,sys; pathlib.Path('/oracle/cache-value').write_text(sys.argv[1])","initial"]
