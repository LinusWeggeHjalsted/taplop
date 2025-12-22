using UnityEngine;
using UnityEngine.UI;

public class SaveButtonScript : MonoBehaviour
{
    public Button button;

    public void OnActivate()
    {
        GameObject player = GameObject.Find("Player");
        PlayerDataScript.Instance.BuildDataFromPlayer(player);
        string savePath = PlayerDataScript.Instance.playerName;
        PlayerDataScript.Instance.SavePlayerData(savePath);
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
