import express from "express";

const PORT = 8080;
const HOST = '0.0.0.0';

const app = express();
app.get('/', (req, res) => {
    res.send("Hello Docker");
})

app.get('/healthcheck', (req, res) => res.sendStatus(200));
app.get('/readiness',   (req, res) => res.sendStatus(200));

app.listen(PORT, HOST, () => {
    console.log(`Running on http://${HOST}:${PORT}`);
});