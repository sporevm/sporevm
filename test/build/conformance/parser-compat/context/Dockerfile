FROM base
WORKDIR /oracle
RUN printf 'joined\n' > mid\
token.txt
RUN [ -f /oracle/midtoken.txt ] && printf 'shell-test\n' > bracket.txt
ENV JOINED=mid\
token
RUN test "$JOINED" = midtoken
COPY file\
name.txt /oracle/copied.txt
CMD [ -f /oracle/copied.txt ] && printf ready
