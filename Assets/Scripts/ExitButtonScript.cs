using UnityEngine;
using UnityEngine.UI;

public class ExitButtonScript : MonoBehaviour
{
    public Button button;

    public void OnActivate()
    {
        GameObject player = GameObject.Find("Player");
        PlayerDataScript.Instance.BuildDataFromPlayer(player);
        if (string.IsNullOrEmpty(PlayerDataScript.Instance.lastHub))
        {
            Debug.Log("going to main menu");
            GameControllerScript.Instance.MainMenu();
        }
        else
        {
            Debug.Log($"going to {PlayerDataScript.Instance.lastHub}");
            GameControllerScript.Instance.EnterHub(PlayerDataScript.Instance.lastHub);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
