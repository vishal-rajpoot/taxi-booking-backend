import swaggerJsDoc from 'swagger-jsdoc';

const swaggerOptions = {
  definition: {
    openapi: '3.0.0',
    info: {
      title: 'Taxi-Booking API Documentation',
      version: '1.0.0',
      description: 'Documentation for Taxi Booking APIs',
    },
    servers: [
      {
        url: 'http://localhost:8090/v1',
        description: 'Development Server',
      },
    ],
  },
  apis: ['./src/apis/**/*.js'],
};

export const swaggerSpecs = swaggerJsDoc(swaggerOptions);
