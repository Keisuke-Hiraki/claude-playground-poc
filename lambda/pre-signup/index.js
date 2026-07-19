const ALLOWED_DOMAINS = (process.env.ALLOWED_SIGNUP_EMAIL_DOMAINS || '')
  .split(',')
  .map((d) => d.trim().toLowerCase())
  .filter(Boolean);

exports.handler = async (event) => {
  const email = event.request.userAttributes.email || '';
  const domain = email.split('@')[1]?.toLowerCase();

  if (!domain || !ALLOWED_DOMAINS.includes(domain)) {
    throw new Error(`SignUp is restricted to ${ALLOWED_DOMAINS.map((d) => '@' + d).join(' and ')} email addresses.`);
  }

  return event;
};
