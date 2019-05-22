Spree::CheckoutController.class_eval do

  before_action :redirect_to_paypal_if_needed, :only => [:update]

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

    pp_request = provider.build_set_express_checkout(express_checkout_request_details(order, items))

    begin
      pp_response = provider.set_express_checkout(pp_request)
      if pp_response.success?
        respond_to do |format|
          format.json {
            render json: {
              redirectCustomPaymentUrl: provider.express_checkout_url(pp_response, useraction: 'commit')
            }
          }
        end
      else
        flash[:error] = Spree.t('flash.generic_error', scope: 'paypal', reasons: pp_response.errors.map(&:long_message).join(" "))
        respond_to do |format|
          format.json {
            render json: {
              redirectCustomPaymentUrl: checkout_state_path(:payment)
            }
          }
        end
      end
    rescue SocketError
      flash[:error] = Spree.t('flash.connection_failed', scope: 'paypal')
      respond_to do |format|
        format.json {
          render json: {
            redirectCustomPaymentUrl: checkout_state_path(:payment)
          }
        }
      end
    end
  end

  private

  def redirect_to_paypal_if_needed
    return unless (params[:state] == "payment")
    return unless params[:order][:payments_attributes]
    return unless payment_method.kind_of?(Spree::Gateway::PayPalExpress)

    paypal_request and return
  end

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

  def express_checkout_request_details order, items
    { SetExpressCheckoutRequestDetails: {
        InvoiceID: order.number,
        BuyerEmail: order.email,
        ReturnURL: confirm_paypal_url(payment_method_id: payment_method.id, utm_nooverride: 1) + "&order=#{order.number}",
        CancelURL:  cancel_paypal_url,
        SolutionType: payment_method.preferred_solution.present? ? payment_method.preferred_solution : "Mark",
        LandingPage: payment_method.preferred_landing_page.present? ? payment_method.preferred_landing_page : "Billing",
        cppheaderimage: payment_method.preferred_logourl.present? ? payment_method.preferred_logourl : "",
        NoShipping: 1,
        PaymentDetails: [payment_details(items)]
    }}
  end

  def payment_method
    Spree::PaymentMethod.find(params[:order][:payments_attributes].first[:payment_method_id])
  end

  def provider
    payment_method.provider
  end

  def payment_details items
    # This retrieves the cost of shipping after promotions are applied
    # For example, if shippng costs $10, and is free with a promotion, shipment_sum is now $10
    shipment_sum = current_order.shipments.map(&:discounted_cost).sum

    # This calculates the item sum based upon what is in the order total, but not for shipping
    # or tax.  This is the easiest way to determine what the items should cost, as that
    # functionality doesn't currently exist in Spree core
    item_sum = current_order.total - shipment_sum - current_order.additional_tax_total

    if item_sum.zero?
      # Paypal does not support no items or a zero dollar ItemTotal
      # This results in the order summary being simply "Current purchase"
      {
        OrderTotal: {
          currencyID: current_order.currency,
          value: current_order.total
        }
      }
    else
      {
        OrderTotal: {
          currencyID: current_order.currency,
          value: current_order.total
        },
        ItemTotal: {
          currencyID: current_order.currency,
          value: item_sum
        },
        ShippingTotal: {
          currencyID: current_order.currency,
          value: shipment_sum,
        },
        TaxTotal: {
          currencyID: current_order.currency,
          value: current_order.additional_tax_total
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
        Name: current_order.bill_address.try(:full_name),
        Street1: current_order.bill_address.address1,
        Street2: current_order.bill_address.address2,
        CityName: current_order.bill_address.city,
        Phone: current_order.bill_address.phone,
        StateOrProvince: current_order.bill_address.state_text,
        Country: current_order.bill_address.country.iso,
        PostalCode: current_order.bill_address.zipcode
    }
  end

  def address_required?
    payment_method.preferred_solution.eql?('Sole')
  end

end
