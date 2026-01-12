using UnityEngine;
using UnityEngine.UI;

public class ContinueButtonScript : MonoBehaviour
{
    public Button button;
    public GameObject optionsMenu;

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickSound(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
        Destroy(optionsMenu);
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        optionsMenu = GameObject.Find("Options Menu(Clone)");
    }
}
