# the base image to start with
FROM node:16

# Create app directory
WORKDIR /usr/src/app

# Get the package.json
COPY package.json ./

# install dependencies in package.json
RUN npm install

# Copy app files
COPY . .

# expose the port our node app will be hosted on
EXPOSE 8080

# start the server
CMD [ "node", "server.js" ]