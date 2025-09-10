FROM node:lts

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm install
RUN npm audit fix

COPY . .

EXPOSE 4000:4000

CMD [ "node", "server.js" ]