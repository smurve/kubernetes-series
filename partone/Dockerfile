FROM node:16
COPY . /app/
RUN "npm install || \
    ((if [ -f npm-debug.log ]; then \
        cat npm-debug.log; \
    fi) && false)"
CMD npm start
