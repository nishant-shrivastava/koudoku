module Koudoku::Subscription
  extend ActiveSupport::Concern

  included do

    # We don't store these one-time use tokens, but this is what Stripe provides
    # client-side after storing the credit card information.
    attr_accessor :credit_card_token

    belongs_to :plan

    # update details.
    before_save :processing!
    def processing!

      Rails.logger.info "\n\n>>>> Inside processing! | self.credit_card_token : #{self.credit_card_token} | self.credit_card_token.present? : #{self.credit_card_token.present?}"

      # if their package level has changed ..
      if changing_plans?
        Rails.logger.info "\n\n >>> 1. Inside Concern::Subscription | changing_plans? : #{changing_plans?}"
        prepare_for_plan_change
        # and a customer exists in stripe ..
        if stripe_id.present?
          Rails.logger.info "\n\n >>> 1.0.1 Inside Concern::Subscription | stripe_id.present? : #{stripe_id.present?}"
          # fetch the customer.
          customer = Stripe::Customer.retrieve(self.stripe_id)

          #check if customer has Credit card attached on Stripe
          Rails.logger.info "\n\n >>> 1.0.1.1 Checking self.credit_card_token present | self.credit_card_token : #{self.credit_card_token}"
          if customer && self.credit_card_token.present?
            Rails.logger.info "\n\n >>> 1.0.1.1 Checking self.credit_card_token present | self.credit_card_token : #{self.credit_card_token}"
            if customer.sources &&
              # Card found, Updating first
              source = customer.sources.first
              Rails.logger.info "\n\n >>> 1.0.1.1.0 Inside CardCheck IF | Found Already present card | source : #{source}"
              source.source = self.credit_card_token
            else
              # No card found, Creating One
              source = customer.sources.create({source: self.credit_card_token})
              Rails.logger.info "\n\n >>> 1.0.1.1.0 Inside CardCheck ELSE | CREATING / Attaching new card | source : #{source}"
            end
            source.save
          end

          # if a new plan has been selected
          if self.plan.present?
            Rails.logger.info "\n\n >>> 1.0.1.1 Inside Concern::Subscription | self.plan.present? : #{stripe_id.present?}"
            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_downgrade if downgrading?
            prepare_for_upgrade if upgrading?

            # update the package level with stripe.
            # Commented on 6 April'16 for resolving API UPDATE issues.
            # customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate)
            if customer.subscriptions && customer.subscriptions.first
              subscription = customer.subscriptions.first
              subscription.plan = self.plan.stripe_id
              if subscription.save
                Rails.logger.info "\n\n >>>> 1.0.1.0.1 Inside Plan Upgrade/Downgrade | Subscription switched to : #{subscription}"
              end
            end

            finalize_downgrade! if downgrading?
            finalize_upgrade! if upgrading?
          # if no plan has been selected.
          else
            Rails.logger.info "\n\n >>> 1.0.1.0 Inside Concern::Subscription | Inside Else | Customer.cancel_subscription"
            prepare_for_cancelation
            # Remove the current pricing.
            self.current_price = nil
            # delete the subscription.
            # Commented on 6 April'16 for resolving API UPDATE issues.
            # customer.cancel_subscription
            if customer.subscriptions && customer.subscriptions.first
              subscription = customer.subscriptions.first
              subscription.plan = ::Plan.basic.stripe_id
              if subscription.save
                Rails.logger.info "\n\n >>>> 1.0.1.0.2 Inside Plan Cancellation | Subscription switched back to Basic"
              end
            end
            finalize_cancelation!
          end
        # when customer DOES NOT exist in stripe ..
        else
          # if a new plan has been selected
          if self.plan.present?
            Rails.logger.info "\n\n >>> 1.1.1 Inside Concern::Subscription | self.plan.present? : #{self.plan.present?}"
            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_new_subscription
            prepare_for_upgrade
            begin
              customer_attributes = {
                description: subscription_owner_description,
                email: subscription_owner_email,
                plan: plan.stripe_id,
                source: credit_card_token # obtained with Stripe.js
              }
              Rails.logger.info "\n\n >>> 1.1.1.1 Inside Concern::Subscription | customer_attributes : #{customer_attributes}"

              if plan.price > 0.0 and credit_card_token.present?
                customer_attributes[:card] = credit_card_token # obtained with Stripe.js
                Rails.logger.info ">>>> Inside Concern::Subscription | credit_card_token : #{credit_card_token}"
              end
              # If the class we're being included in supports coupons ..
              if respond_to? :coupon
                if coupon.present? and coupon.free_trial?
                  customer_attributes[:trial_end] = coupon.free_trial_ends.to_i
                end
              end

              customer_attributes[:coupon] = @coupon_code if @coupon_code
              # create a customer at that package level.
              customer = Stripe::Customer.create(customer_attributes)

              finalize_new_customer!(customer.id, plan.price)
              customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate)
            rescue Stripe::CardError => card_error
              errors[:base] << card_error.message
              card_was_declined
              return false
            end
            # store the customer id.
            self.stripe_id = customer.id
            self.last_four = customer.sources.retrieve(customer.default_source).last4 if customer.sources.count > 0

            finalize_new_subscription!
            finalize_upgrade!
          else
            Rails.logger.info "\n\n >>> 1.1.0 Inside Concern::Subscription | Inside Else | Setting Plan to Basic, if nothing is present."
            # This should never happen.
            self.plan_id = ::Plan.basic.id
            # Remove any plan pricing.
            self.current_price = ::Plan.basic.price
          end
        end
        finalize_plan_change!
      elsif self.credit_card_token.present?
        # if they're updating their credit card details.
        # @TODO : Also check whether the User has the same card details as before.
        # Check with stripe, rather than in DB.

        Rails.logger.info "\n\n >>> 2. Inside Concern::Subscription | self.credit_card_token.present? : #{self.credit_card_token.present?}"
        prepare_for_card_update
        # fetch the customer.
        customer = Stripe::Customer.retrieve(self.stripe_id)
        Rails.logger.info "\n\n >>>> Inside self.credit_card_token.present? | customer (from Stripe) : #{customer}"
        customer.card = self.credit_card_token
        customer.save

        # update the last four based on this new card.
        self.last_four = customer.sources.retrieve(customer.default_source).last4
        finalize_card_update!
      end
    end
  end

  def describe_difference(plan_to_describe)
    if plan.nil?
      if persisted?
        I18n.t('koudoku.plan_difference.upgrade')
      else
        if Koudoku.free_trial?
          I18n.t('koudoku.plan_difference.start_trial')
        else
          I18n.t('koudoku.plan_difference.upgrade')
        end
      end
    else
      if plan_to_describe.is_upgrade_from?(plan)
        I18n.t('koudoku.plan_difference.upgrade')
      else
        I18n.t('koudoku.plan_difference.downgrade')
      end
    end
  end

  # Set a Stripe coupon code that will be used when a new Stripe customer (a.k.a. Koudoku subscription)
  # is created
  def coupon_code=(new_code)
    @coupon_code = new_code
  end

  # Pretty sure this wouldn't conflict with anything someone would put in their model
  def subscription_owner
    # Return whatever we belong to.
    # If this object doesn't respond to 'name', please update owner_description.
    send Koudoku.subscriptions_owned_by
  end

  def subscription_owner=(owner)
    # e.g. @subscription.user = @owner
    send Koudoku.owner_assignment_sym, owner
  end

  def subscription_owner_description
    # assuming owner responds to name.
    # we should check for whether it responds to this or not.
    "#{subscription_owner.try(:name) || subscription_owner.try(:id)}"
  end

  def subscription_owner_email
    "#{subscription_owner.try(:email)}"
  end

  def changing_plans?
    plan_id_changed?
  end

  def downgrading?
    plan.present? and plan_id_was.present? and plan_id_was > self.plan_id
  end

  def upgrading?
    (plan_id_was.present? and plan_id_was < plan_id) or plan_id_was.nil?
  end

  # Template methods.
  def prepare_for_plan_change
  end

  def prepare_for_new_subscription
  end

  def prepare_for_upgrade
  end

  def prepare_for_downgrade
  end

  def prepare_for_cancelation
  end

  def prepare_for_card_update
  end

  def finalize_plan_change!
  end

  def finalize_new_subscription!
  end

  def finalize_new_customer!(customer_id, amount)
  end

  def finalize_upgrade!
  end

  def finalize_downgrade!
  end

  def finalize_cancelation!
  end

  def finalize_card_update!
  end

  def card_was_declined
  end

  # stripe web-hook callbacks.
  def payment_succeeded(amount)
  end

  def charge_failed
  end

  def charge_disputed
  end
end