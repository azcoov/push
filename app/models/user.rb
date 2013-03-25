module StripePush
  class User
    include MongoMapper::Document

    key :uid, String, :required => true
    key :publishable_key, String, :required => true
    key :secret_key, String, :required => true
    key :device_tokens, Array, :default => []
    key :email, String
    key :charge_notifications, Integer, :default => 0
    key :charge_amount, Integer, :default => 0
    key :transfer_notifications, Integer, :default => 0

    attr_accessible :charge_notifications, :transfer_notifications

    def self.from_auth!(auth)
      user                 = find_by_uid(auth['uid']) || self.new
      user.uid             = auth['uid']
      user.secret_key      = auth['credentials']['token']
      user.publishable_key = auth['info']['stripe_publishable_key']
      user.retrieve_account!
      user.save!
      user
    end

    def self.pusher
      Grocer.pusher(certificate: settings.certificate_path)
    end

    def self.notify(token, options = {})
      notification = Grocer::Notification.new(
        {device_token: token}.merge(options)
      )
      self.pusher.push(notification)
    end

    def retrieve_account!
      account    = Stripe::Account.retrieve(secret_key)
      self.email = account.email
      self.save!
    end

    def notify_event!(event)
      case event.type
      when 'charge.succeeded'
        notify_charge(event.data.object)
      when 'transfer.created', 'transfer.updated'
        notify_transfer(event.data.object)
      end
    end

    def add_token!(token)
      self.device_tokens |= [token]
      self.save!
    end

    def remove_token!(token)
      self.device_tokens -= [token]
      self.save!
    end

    def alert(msg)
      notify(alert: msg)
    end

    def as_json(options = {})
      {
        uid:                    uid,
        email:                  email,
        charge_notifications:   charge_notifications,
        transfer_notifications: transfer_notifications
      }
    end

    protected

    def notify(options = {})
      self.device_tokens.each do |id|
        self.class.notify(id, options)
      end
    end

    def transfer_notifications_enabled?
      transfer_notifications != -1
    end

    def charge_notifications_enabled?
      charge_notifications != -1
    end

    def notify_charge(charge)
      return unless charge_notifications_enabled?

      if charge_notifications == 0
        # Notify every charge
        notify_single_charge(charge)

      else
        # Notify every n amount
        self.charge_amount += charge.amount

        if self.charge_amount >= self.charge_notifications
          notify_batch_charges(self.charge_amount, charge.currency)
          self.charge_amount = 0
        end

        self.save
      end
    end

    def notify_single_charge(charge)
      money = Money.new(charge.amount, charge.currency)

      alert  = "Paid #{money.symbol}#{money.to_s}"
      alert += " - #{charge.description}" if charge.description
      alert += "."

      custom = {
        amount:      charge.amount,
        description: charge.description || ''
      }

      notify(alert: alert, custom: custom)
    end

    def notify_batch_charges(amount, currency)
      money  = Money.new(amount, currency)
      alert  = "Paid #{money.symbol}#{money.to_s}."

      custom = {
        amount: amount,
        batch: true
      }

      notify(alert: alert, custom: custom)
    end

    def notify_transfer(transfer)
      return unless transfer_notifications_enabled?

      money = Money.new(transfer.amount, transfer.currency)
      alert = "#{money.symbol}#{money.to_s} is being transferred into your bank account."

      custom = {
        amount:      transfer.amount,
        description: transfer.description || ''
      }

      notify(alert: alert, custom: custom)
    end
  end
end