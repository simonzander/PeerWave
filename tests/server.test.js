const request = require('supertest');
const { randomUUID } = require('crypto');
const { isValidUUID, callbackHandler, server, app } = require('../server'); // Adjust the path if necessary
const clientSocket = require('socket.io-client')(`http://localhost:4000`); // Adjust the URL if necessary


describe('Server Tests', () => {

    beforeAll((done) => {
            clientSocket.connect();
            clientSocket.on('connect', done);
    });

    afterAll((done) => {
        if (clientSocket.connected) {
            clientSocket.disconnect();
        }
        server.close(done);
    });

    

    test('should validate UUID correctly', () => {
        expect(isValidUUID(randomUUID())).toBe(true);
        expect(isValidUUID('invalid-uuid')).toBe(false);
    });

    test('should handle callback correctly', () => {
        const mockCallback = jest.fn();
        callbackHandler(mockCallback, 'test data');
        expect(mockCallback).toHaveBeenCalledWith('test data');
    });

    test('should render meet page', async () => {
        const response = await request(app).get('/meet');
        expect(response.status).toBe(200);
    });

    test('should render host page', async () => {
        const response = await request(app).get('/host');
        expect(response.status).toBe(200);
    });

    test('should render about page', async () => {
        const response = await request(app).get('/');
        expect(response.status).toBe(200);
    });

    test('should render view page with room ID', async () => {
        const roomId = randomUUID();
        const response = await request(app).get(`/view/${roomId}`);
        expect(response.status).toBe(200);
    });

    test('should render meet page with room ID', async () => {
        const roomId = randomUUID();
        const response = await request(app).get(`/meet/${roomId}`);
        expect(response.status).toBe(200);
    });

    test('should render share page with room ID', async () => {
        const roomId = randomUUID();
        const response = await request(app).get(`/share/${roomId}`);
        expect(response.status).toBe(200);
    });

    test('should handle socket connection and host event', (done) => {
        clientSocket.emit('host', 5, (room) => {
            expect(isValidUUID(room)).toBe(true);
            done();
        });
    });
});