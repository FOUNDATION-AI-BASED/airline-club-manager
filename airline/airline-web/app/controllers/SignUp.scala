package controllers

import play.api.mvc._
import play.api.data._
import play.api.data.Forms._

import javax.inject._
import views._
import models._
import com.patson.data.UserSource
import com.patson.model._
import com.patson.Authentication

import java.util.Calendar
import com.patson.data.AirlineSource
import com.patson.util.AirlineCache
import play.api.libs.ws.WSClient

import scala.concurrent.duration.Duration
import java.util.concurrent.TimeUnit
import scala.concurrent.Await
import play.api.libs.json.Writes
import play.api.libs.json.Json
import play.api.libs.json.JsValue
import play.api.libs.json.JsObject
import play.api.libs.json.JsNumber
import play.api.libs.json.JsString

class SignUp @Inject()(cc: ControllerComponents)(ws: WSClient) extends AbstractController(cc) with play.api.i18n.I18nSupport {
  // Removed reCAPTCHA related vals
  // private[this] val recaptchaUrl = "https://www.google.com/recaptcha/api/siteverify"
  // private[this] val recaptchaAction = "signup"
  // private[this] val recaptchaSecret = "6LespV8UAAAAAErZ7LWP51SWmYaYrnAz6Z61jKBC"
  // private[this] val recaptchaScoreThreshold = 0.5
  
  /**
   * Sign Up Form definition.
   *
   * Once defined it handle automatically, ,
   * validation, submission, errors, redisplaying, ...
   */
  val signupForm: Form[NewUser] = Form(
    
    // Define a mapping that will handle User values
    mapping(
      "username" -> text(minLength = 4, maxLength = 20).verifying(
        "username can only contain alphanumeric characters",
        (userName: String) => userName.forall(char => char.isLetterOrDigit && char <= 'z')
      ).verifying(
        "This username is not available",
        (userName: String) => UserSource.isUserNameAvailable(userName.toLowerCase())
      ),
      "email" -> email,
      // Create a tuple mapping for the password/confirm
      "password" -> tuple(
        "main" -> text(minLength = 6),
        "confirm" -> text
      ).verifying(
        // Add an additional constraint: both passwords must match
        "Passwords don't match", passwords => passwords._1 == passwords._2
      ),
      "airlineName" -> text(minLength = 1, maxLength = 30).verifying(
        "This airline name is not available",
        (airlineName: String) => UserSource.isAirlineNameAvailable(airlineName.toLowerCase())
      )
    )
    // The mapping signature doesn't match the User case class signature,
    // so we have to define custom binding/unbinding functions
    {
      // Binding: Create a User from the mapping result (ignore the second password and the accept field)
      (username: String, email: String, passwords: (String, String), airlineName: String) => NewUser(username.trim, passwords._1, email.trim, airlineName.trim)
    }
    {
      // Unbinding: Create the mapping values from an existing User value
      user => Some(user.username, user.email, (user.password, ""), user.airlineName)
    }
  )
  
  /**
   * Display an empty form.
   */
  def form = Action { implicit request =>
    Ok(html.signup(signupForm))
  }
  
  /**
   * Display a form pre-filled with an existing User.
   */
//  def editForm = Action {
//    val existingUser = NewUser("fakeuser", "secret", "fake@gmail.com") 
//    Ok(html.signup(signupForm.fill(existingUser)))
//  }

  def airlineNameCheck(airlineName : String)= Action { implicit request =>
    AirlineUtil.checkAirlineName(airlineName) match {
      case Some(rejection) => Ok(Json.obj("rejection" -> rejection))
      case None => Ok(Json.obj("ok" -> true))
    }
  }


   /**
   * Handle form submission.
   */
  def submit = Action { implicit request =>
    signupForm.bindFromRequest().fold(
      // Form has errors, redisplay it
      errors => BadRequest(html.signup(errors)), { userInput =>
        
        // We got a valid User value, display the summary
        val user = User(userInput.username, userInput.email, Calendar.getInstance, Calendar.getInstance, UserStatus.ACTIVE, level = 0, None, List.empty)
        UserSource.saveUser(user)
        Authentication.createUserSecret(userInput.username, userInput.password)
        
        val newAirline = Airline(userInput.airlineName)
//        newAirline.setBalance(50000000) //initial balance 50 million
        newAirline.setMaintenanceQuality(100)
        newAirline.setAirlineCode(newAirline.getDefaultAirlineCode())
        AirlineSource.saveAirlines(List(newAirline))
        UserSource.setUserAirline(user, newAirline)
    
        SearchUtil.addAirline(newAirline)
        
//        val profile = StartupProfile.profilesById(userInput.profileId)
//        profile.initializeAirline(newAirline)
        Redirect("/").withCookies(Cookie("sessionActive", "true", httpOnly = false)).withSession("userToken" -> SessionUtil.addUserId(user.id))
      }
    )
  }
  
  // Removed isValidRecaptcha function
}