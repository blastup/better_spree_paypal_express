Spree::Api::V1::CheckoutsController.class_eval do

  skip_before_action :authenticate_user, :only => [:paypal_response]

  def update
    authorize! :update, @order, order_token

    need_to_redirect = false

    if params["state"] == "payment"
      payment_method = Spree::PaymentMethod.find_by_id(params["order"]["payments_attributes"][0]["payment_method_id"])

      if payment_method && payment_method.type == "Spree::Gateway::PayPalExpress"
        
        pp_request = paypal_request

        need_to_redirect = true
        begin
          pp_response = provider.set_express_checkout(pp_request)
          if pp_response.success?
            Rails.logger.info "~~PayPal-response~~"
            Rails.logger.info pp_response

            @payment_redirect_url = provider.express_checkout_url(pp_response, useraction: 'commit')
            respond_with(@order, default_template: 'spree/api/v1/orders/show') and return
          else
            Rails.logger.info "~~PayPal-response ERROR~~"
            Rails.logger.info pp_response.errors.map(&:long_message).join(" ")
            respond_with(@order, default_template: 'spree/api/v1/orders/could_not_transition', status: 422)
          end
        rescue SocketError
          respond_with(@order, default_template: 'spree/api/v1/orders/could_not_transition', status: 422)
        end
      end
    end

    unless need_to_redirect
      if @order.update_from_params(params, permitted_checkout_attributes, request.headers.env)
        if current_api_user.has_spree_role?('admin') && user_id.present?
          @order.associate_user!(Spree.user_class.find(user_id))
        end

        return if after_update_attributes

        if @order.completed? || @order.next
          state_callback(:after)
          respond_with(@order, default_template: 'spree/api/v1/orders/show')
        else
          respond_with(@order, default_template: 'spree/api/v1/orders/could_not_transition', status: 422)
        end
      else
        invalid_resource!(@order)
      end
    end
  end

  def paypal_request
    order = @order || raise(ActiveRecord::RecordNotFound)
    items = order.line_items.map(&method(:line_item))

    additional_adjustments = order.all_adjustments.additional
    tax_adjustments = additional_adjustments.tax
    shipping_adjustments = additional_adjustments.shipping

    additional_adjustments.eligible.each do |adjustment|
      # Because PayPal doesn't accept $0 items at all. See #10
      # https://cms.paypal.com/uk/cgi-bin/?cmd=_render-content&content_ID=developer/e_howto_api_ECCustomizing
      # "It can be a positive or negative value but not zero."
      next if adjustment.amount.zero?
      next if tax_adjustments.include?(adjustment) || shipping_adjustments.include?(adjustment)

      items << {
        Name: adjustment.label,
        Quantity: 1,
        Amount: {
          currencyID: order.currency,
          value: adjustment.amount
        }
      }
    end

    provider.build_set_express_checkout(express_checkout_request_details(order, items))
  end

  def paypal_response
    success = false

    if params[:order].present?
      order = Spree::Order.where(:number => params[:order]).first

      if order
        order.payments.create!({
          source: Spree::PaypalExpressCheckout.create({
            token: params[:token],
            payer_id: params[:PayerID]
          }),
          amount: order.total,
          payment_method: payment_method
        })
        order.next
        if order.complete?
          session[:order_id] = nil
          redirect_to("#{Rails.application.config.client_host}/checkout/complete?orderNumber=#{order.number}") and return
        else
          redirect_to("#{Rails.application.config.client_host}/checkout") and return
        end
        success = true
      end
    end

    unless success
      redirect_to("#{Rails.application.config.client_host}/checkout?payment_error=#{t(:paypal_payment_failed)}") and return
    end
  end

  private
    def line_item(item)
      {
          Name: item.product.name,
          Number: item.variant.sku,
          Quantity: item.quantity,
          Amount: {
              currencyID: item.order.currency,
              value: item.price
          },
          ItemCategory: "Physical"
      }
    end

    def express_checkout_request_details(order, items)
      { SetExpressCheckoutRequestDetails: {
          InvoiceID: order.number,
          BuyerEmail: order.email,
          ReturnURL: "#{Rails.application.config.server_host}/api/v1/orders/checkouts/paypal_response?order=#{order.number}&payment_method_id=#{payment_method.id}",
          CancelURL: "#{Rails.application.config.client_host}/checkout?cancel_message=#{t(:paypal_canceled)}",
          SolutionType: payment_method.preferred_solution.present? ? payment_method.preferred_solution : "Mark",
          LandingPage: payment_method.preferred_landing_page.present? ? payment_method.preferred_landing_page : "Billing",
          cppheaderimage: payment_method.preferred_logourl.present? ? payment_method.preferred_logourl : "",
          NoShipping: 1,
          PaymentDetails: [payment_details(items)]
      }}
    end

    def payment_method
      Spree::PaymentMethod.find_by_id(params["payment_method_id"] || params["order"]["payments_attributes"][0]["payment_method_id"])
    end

    def provider
      payment_method.provider
    end

    def payment_details(items)
      # This retrieves the cost of shipping after promotions are applied
      # For example, if shippng costs $10, and is free with a promotion, shipment_sum is now $10
      shipment_sum = @order.shipments.map(&:discounted_cost).sum

      # This calculates the item sum based upon what is in the order total, but not for shipping
      # or tax.  This is the easiest way to determine what the items should cost, as that
      # functionality doesn't currently exist in Spree core
      item_sum = @order.total - shipment_sum - @order.additional_tax_total

      if item_sum.zero?
        # Paypal does not support no items or a zero dollar ItemTotal
        # This results in the order summary being simply "Current purchase"
        {
          OrderTotal: {
            currencyID: @order.currency,
            value: @order.total
          }
        }
      else
        {
          OrderTotal: {
            currencyID: @order.currency,
            value: @order.total
          },
          ItemTotal: {
            currencyID: @order.currency,
            value: item_sum
          },
          ShippingTotal: {
            currencyID: @order.currency,
            value: shipment_sum,
          },
          TaxTotal: {
            currencyID: @order.currency,
            value: @order.additional_tax_total
          },
          ShipToAddress: address_options,
          PaymentDetailsItem: items,
          ShippingMethod: "Shipping Method Name Goes Here",
          PaymentAction: "Sale"
        }
      end
    end

    def address_options
      return {} unless address_required?

      {
          Name: @order.bill_address.try(:full_name),
          Street1: @order.bill_address.address1,
          Street2: @order.bill_address.address2,
          CityName: @order.bill_address.city,
          Phone: @order.bill_address.phone,
          StateOrProvince: @order.bill_address.state_text,
          Country: @order.bill_address.country.iso,
          PostalCode: @order.bill_address.zipcode
      }
    end

    def completion_route(order)
      order_path(order)
    end

    def address_required?
      payment_method.preferred_solution.eql?('Sole')
    end
end