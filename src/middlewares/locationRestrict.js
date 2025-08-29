import axios from 'axios';
// import { europeanCountries } from '../constants/index.js';
// import { COUNTRIES } from '../constants/index.js';
import { logger } from '../utils/logger.js';
import { processPayInRestricted } from '../utils/updateRestrictedLocationPayin.js';
import { getPayInwithMerchantDao } from '../apis/payIn/payInDao.js';
const BLOCK_LAT = process.env.BLOCK_LAT;
const BLOCK_LONG = process.env.BLOCK_LONG;
const PROXY_CHECK_URL = process.env.PROXY_CHECK_URL;
const TestingIp = process.env.LOCAL_IP;
const getUserLocationMiddleware = async (req, res, next) => {
  let userIp =
    req.headers['x-forwarded-for'] || req.connection.remoteAddress || req.ip;
  if (userIp == '::1') {
    userIp = TestingIp;
  }
  const userIpShouldBlock = '13.41.235.43';
  if (userIp === userIpShouldBlock) {
    logger.warn('Fraud User. Access denied.', userIp);
    return res.status(403).send('403: Access denied');
  }
  const restrictedLocation = { latitude: BLOCK_LAT, longitude: BLOCK_LONG };
  const radiusKm = 60;
  // let restrictedStates = ['Haryana', 'Rajasthan'];
  try {
    // Get the user's IP address (checking for reverse proxy headers)
    // Send a request to proxycheck.io to fetch the geolocation data
    let url = PROXY_CHECK_URL.replace('$%7BuserIp%7D', userIp);
    const response = await axios.get(url);

    const userData = response.data[userIp];
    if (!userData) {
      return res.status(500).json({ message: 'Error fetching location data' });
    }
    const { latitude, longitude, vpn, region, country } = userData;
    const payInUrl = await getPayInwithMerchantDao(req.params.merchantOrderId);
    const isIpBlocked = payInUrl.blocked_users_ip[0]?.user_ip.includes(userIp);
    if (isIpBlocked) {
      const url = await processPayInRestricted(
        payInUrl,
        `Restricted User IP: ${userIp}`,
      );
      logger.warn(
        'Blocked user IP. Access denied.',
        { userIp },
      );
      return res.status(403).json({
        error: { message: 'Access Denied!', data: { url } },
      });
    }
    const isIdBlocked = payInUrl.blocked_users_id[0]?.userId.includes(
      payInUrl.userid,
    );
    if (isIdBlocked) {
      const url = await processPayInRestricted(
        payInUrl,
        `Restricted User: ${payInUrl.userid}`,
      );
      logger.warn(
        'Blocked user ID. Access denied.',
      );
      return res.status(403).json({
        error: { message: 'Access Denied!', data: { url } },
      });
    }
    if (vpn === 'yes') {
      // const id = req.params.merchantOrderId;
      const url = await processPayInRestricted(payInUrl, 'VPN detected');
      logger.warn('VPN detected. Access denied.', userData);
      return res.status(403).json({
        error: { message: 'VPN is Not Allowed!', data: { url } },
      });
    }
    // let rakpayId = 'eb58a8cb-dee6-46fb-878b-3f24272cf980';
    if (payInUrl.unblockedcountries) {
      const countryData = payInUrl.unblockedcountries.find(
        (c) => c.country === country,
      );
      if (!countryData) {
        // Country not in unblockedcountries
        // const id = req.params.merchantOrderId;
        const url = await processPayInRestricted(
          payInUrl,
          `Restricted country: ${country}`,
        );
        logger.error(`Access restricted for users from ${country}.`, userData);
        return res.status(403).json({
          error: { message: 'Oops ! Service not available', data: { url } },
        });
      }
      if (
        countryData.regions.length > 0 &&
        !countryData.regions.includes(region)
      ) {
        // const id = req.params.merchantOrderId;
        const url = await processPayInRestricted(
          payInUrl,
          `Restricted region: ${region}`,
        );
        logger.error(`Access restricted for users in ${region}.`, userData);
        return res.status(403).json({
        
          error: { message: 'Oops ! Service not available', data: { url } },
        });
      }
    }
    if (!isNaN(latitude) && !isNaN(longitude)) {
      // Check if the user is in the restricted region
      if (
        isLocationBlocked(
          latitude,
          longitude,
          restrictedLocation.latitude,
          restrictedLocation.longitude,
          radiusKm,
        )
      ) {
        logger.error('Access restricted in your region.', userData);
        return res.status(403).send('Access Denied!');
      }
    } else {
      logger.warn('Invalid latitude/longitude data received.');
      return res.status(500).send('500: Access denied');
    }
    req.user_location = {
      user_ip: userIp,
      continent: userData.continent,
      continent_code: userData.continentcode,
      country: userData.country,
      region: userData.region,
      timezone: userData.timezone,
      city: userData.city,
      postcode: userData.postcode,
      latitude: userData.latitude,
      longitude: userData.longitude,
    };
    next();
  } catch (error) {
    logger.error('Error fetching user location:', error);
    res.status(500).json({ message: 'Error fetching user location' });
  }
};
const isLocationBlocked = (
  userLat,
  userLon,
  restrictedLat,
  restrictedLon,
  radiusKm,
) => {
  const distance = haversineDistance(
    userLat,
    userLon,
    restrictedLat,
    restrictedLon,
  );
  return distance <= radiusKm;
};
const haversineDistance = (lat1, lon1, lat2, lon2) => {
  const toRadians = (degrees) => (degrees * Math.PI) / 180;
  const R = 6371;
  const dLat = toRadians(lat2 - lat1);
  const dLon = toRadians(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRadians(lat1)) *
      Math.cos(toRadians(lat2)) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
};
export default getUserLocationMiddleware;
