using UnityEngine;
using UnityEngine.UI;

public class NewGameButtonScript : MonoBehaviour
{
    Button button;

    public void OnActivate()
    {
        PlayerDataScript.Instance.LoadPlayerData("DevSave");
        // to-do - pick a random seed
//        GameControllerScript.Instance.StartMission("Beginnings", 3, "TestHub");
        GameControllerScript.Instance.EnterHub("TestHub");
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
