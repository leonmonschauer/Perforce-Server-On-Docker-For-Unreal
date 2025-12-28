#!/bin/bash
set +e
export NAME="${NAME:-p4depot}"
export CASE_INSENSITIVE="${CASE_INSENSITIVE:-0}"
export P4ROOT="${DATAVOLUME}/${NAME}"


# Ensure SSL directory exists
SSL_DIR="${P4ROOT}/ssl"
if [ ! -d "$SSL_DIR" ]; then
    echo "SSL directory does not exist. Creating it..."
    mkdir -p "$SSL_DIR"
    chown perforce:perforce "$SSL_DIR"
fi

# Check if SSL certificate files exist
if [ ! -f "$SSL_DIR/server.crt" ] || [ ! -f "$SSL_DIR/server.key" ]; then
    echo "SSL certificate or key files not found. Generating self-signed SSL certificates..."

    # Generate a self-signed SSL certificate and private key
    openssl req -x509 -newkey rsa:2048 -keyout "$SSL_DIR/server.key" -out "$SSL_DIR/server.crt" -days 365 -nodes -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=localhost"
    
    # Set the correct permissions
    chmod 600 "$SSL_DIR/server.key"
    chmod 644 "$SSL_DIR/server.crt"

    # Change ownership to the 'perforce' user
    chown perforce:perforce "$SSL_DIR/server.key"
    chown perforce:perforce "$SSL_DIR/server.crt"
fi


if [ ! -d $DATAVOLUME/etc ]; then
    echo >&2 "First time installation, copying configuration from /etc/perforce to $DATAVOLUME/etc and relinking"
    mkdir -p $DATAVOLUME/etc
    cp -r /etc/perforce/* $DATAVOLUME/etc/
    FRESHINSTALL=1
fi

mv /etc/perforce /etc/perforce.orig
ln -s $DATAVOLUME/etc /etc/perforce

if [ -z "$P4PASSWD" ]; then
    P4PASSWD="pass12349ers!"
fi

# This is hardcoded in configure-helix-p4d.sh :(
P4SSLDIR="$P4ROOT/ssl"

for DIR in $P4ROOT $P4SSLDIR; do
    mkdir -m 0700 -p $DIR
    chown perforce:perforce $DIR
done

if ! p4dctl list 2>/dev/null | grep -q $NAME; then
    /opt/perforce/sbin/configure-helix-p4d.sh $NAME -n -p $P4PORT -r $P4ROOT -u $P4USER -P "${P4PASSWD}" --case 1 # Forcing case insensitive as it is recommended for Unreal projects
fi

# Start the Perforce server
p4dctl start -t p4d $NAME

# Wait for the Perforce server to initialize (check for the PID file)
MAX_RETRIES=10
RETRY_COUNT=0

echo "Waiting for Perforce server to initialize..."

# Check if the server is accepting connections on the specified port (1666 or ssl:1666)
while ! nc -z localhost 1666; do  # Use ssl:1666 if SSL is enabled
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "Perforce server failed to start after $MAX_RETRIES attempts."
    exit 1  # Exit the script with an error code
  fi
  echo "Attempt $((RETRY_COUNT + 1)) of $MAX_RETRIES: Waiting for Perforce server to initialize..."
  sleep 2
  RETRY_COUNT=$((RETRY_COUNT + 1))
done

echo "Perforce server is up and running on port 1666."

# If SSL is enabled, set P4PORT to ssl:1666
if echo "$P4PORT" | grep -q '^ssl:'; then
    echo "SSL is enabled, setting P4PORT to $P4PORT"
else
    echo "SSL is not enabled, using non-SSL port 1666"
    P4PORT=1666
fi

# Now write to the .p4config file
cat > ~perforce/.p4config <<EOF
P4USER=$P4USER
P4PASSWD=$P4PASSWD
P4PORT=$P4PORT
EOF

chmod 0600 ~perforce/.p4config
chown perforce:perforce ~perforce/.p4config

if echo "$P4PORT" | grep -q '^ssl:'; then
	echo "Setting trust"
    p4 trust -y
fi

# Login to Perforce (initial password)
echo "Logging in to Perforce with password $P4PASSWD..."
#p4 login <<EOF
#$P4PASSWD
#EOF

if [ "$FRESHINSTALL" = "1" ]; then
    ## Load up the default tables
    echo >&2 "First time installation, setting up defaults for p4 user, group and protect tables"
    p4 user -i < /root/p4-users.txt
    p4 group -i < /root/p4-groups.txt
    p4 protect -i < /root/p4-protect.txt

    # disable automatic user account creation
    p4 configure set lbr.proxy.case=1

    # disable unauthorized viewing of Perforce user list
    p4 configure set run.users.authorize=1

    # disable unauthorized viewing of Perforce config settings
    p4 configure set dm.keys.hide=2

    # Update the Typemap
    # Based on : https://x157.github.io/Perforce/Typemap
	cat /root/typemap.txt | p4 typemap -i
	
	# Set perforce server to Unicode so it plays nice with Swarm
	p4d -xi

fi

echo "   P4USER=$P4USER (the admin user)"

if [ "$P4PASSWD" == "pass12349ers!" ]; then
    echo -e "\n***** WARNING: USING DEFAULT PASSWORD ******\n"
    echo "Please change as soon as possible:"
    echo "   P4PASSWD=$P4PASSWD"
    echo -e "\n***** WARNING: USING DEFAULT PASSWORD ******\n"
fi

# exec /usr/bin/p4web -U perforce -u $P4USER -b -p $P4PORT -P "$P4PASSWD" -w 8080

